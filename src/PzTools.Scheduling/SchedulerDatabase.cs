using System.Globalization;
using Microsoft.Data.Sqlite;
using PzTools.Process.Contracts;

namespace PzTools.Scheduling;

public sealed partial class SchedulerDatabase
{
    private const int CurrentSchemaVersion = 5;
    private readonly string connectionString;

    private SchedulerDatabase(string path)
    {
        DatabasePath = path;
        connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false,
        }.ToString();
    }

    public string DatabasePath { get; }

    public static async Task<SchedulerDatabase> CreateOrOpenAsync(
        string path,
        CancellationToken cancellationToken = default)
    {
        var absolute = Path.GetFullPath(path);
        Directory.CreateDirectory(Path.GetDirectoryName(absolute)!);
        var database = new SchedulerDatabase(absolute);
        await using var connection = await database.OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='scheduler_info';";
        var hasExistingSchema = Convert.ToInt32(
            await command.ExecuteScalarAsync(cancellationToken),
            CultureInfo.InvariantCulture) != 0;
        if (hasExistingSchema)
        {
            command.CommandText =
                "SELECT schema_version FROM scheduler_info WHERE singleton=1;";
            var existingVersion = Convert.ToInt32(
                await command.ExecuteScalarAsync(cancellationToken),
                CultureInfo.InvariantCulture);
            if (existingVersion > CurrentSchemaVersion)
            {
                throw new InvalidDataException(
                    $"Scheduler schema {existingVersion} is newer than supported schema {CurrentSchemaVersion}.");
            }
        }
        command.CommandText =
            """
            CREATE TABLE IF NOT EXISTS scheduler_info(
                singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                schema_version INTEGER NOT NULL,
                scheduler_revision INTEGER NOT NULL DEFAULT 0
            ) STRICT;
            INSERT OR IGNORE INTO scheduler_info(singleton,schema_version) VALUES(1,4);

            CREATE TABLE IF NOT EXISTS backup_scheduler_control(
                singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                repository_path TEXT NOT NULL,
                automatic_enabled INTEGER NOT NULL CHECK(automatic_enabled IN (0,1)),
                interval_minutes INTEGER NOT NULL CHECK(interval_minutes BETWEEN 1 AND 60),
                current_save_id TEXT NULL,
                current_source_key TEXT NULL,
                current_source_path TEXT NULL,
                mode TEXT NOT NULL CHECK(mode IN ('Paused','Continuous','Limited','Ambiguous')),
                attempts_remaining INTEGER NOT NULL,
                generation INTEGER NOT NULL,
                next_due_utc TEXT NOT NULL,
                last_run_index INTEGER NULL,
                last_outcome TEXT NULL
            ) STRICT;

            CREATE TABLE IF NOT EXISTS backup_target_commands(
                idempotency_key TEXT PRIMARY KEY,
                command TEXT NOT NULL CHECK(command IN(
                    'ActivateTarget','FinalizeTarget','ClearTarget','RunOnceNow','SuspendAmbiguous')),
                save_id TEXT NOT NULL,
                source_key TEXT NOT NULL,
                source_path TEXT NOT NULL,
                transition_id TEXT NULL,
                cause_run_index INTEGER NULL,
                received_utc TEXT NOT NULL,
                applied_utc TEXT NULL
            ) STRICT;

            CREATE TABLE IF NOT EXISTS pending_backup_runs(
                pending_id TEXT PRIMARY KEY,
                kind TEXT NOT NULL CHECK(kind IN('Final','RunOnce')),
                save_id TEXT NOT NULL,
                source_key TEXT NOT NULL,
                source_path TEXT NOT NULL,
                attempt_sequence INTEGER NOT NULL DEFAULT 1,
                enqueued_utc TEXT NOT NULL
            ) STRICT;

            CREATE TABLE IF NOT EXISTS state_scheduler(
                singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                interval_seconds INTEGER NOT NULL CHECK(interval_seconds > 0),
                next_due_utc TEXT NOT NULL,
                next_run_index INTEGER NOT NULL
            ) STRICT;

            -- A timed pause of automatic backups is gone: the setting turns them off. A pause left behind goes too.
            DROP TABLE IF EXISTS backup_pause;
            """;
        await command.ExecuteNonQueryAsync(cancellationToken);

        command.CommandText =
            "SELECT schema_version FROM scheduler_info WHERE singleton=1;";
        var schemaVersion = Convert.ToInt32(
            await command.ExecuteScalarAsync(cancellationToken),
            CultureInfo.InvariantCulture);
        if (schemaVersion > CurrentSchemaVersion)
        {
            throw new InvalidDataException(
                $"Scheduler schema {schemaVersion} is newer than supported schema {CurrentSchemaVersion}.");
        }

        await MigrateAmbiguousModeAsync(connection, cancellationToken);
        command.CommandText = RuntimeSchema;
        await command.ExecuteNonQueryAsync(cancellationToken);

        command.CommandText =
            "SELECT COUNT(*) FROM pragma_table_info('scheduler_info') "
            + "WHERE name='scheduler_revision';";
        var hasRevision = Convert.ToInt32(
            await command.ExecuteScalarAsync(cancellationToken),
            CultureInfo.InvariantCulture) != 0;
        if (!hasRevision)
        {
            command.CommandText =
                "ALTER TABLE scheduler_info ADD COLUMN scheduler_revision INTEGER NOT NULL DEFAULT 0;";
            await command.ExecuteNonQueryAsync(cancellationToken);
        }

        command.CommandText =
            $"UPDATE scheduler_info SET schema_version={CurrentSchemaVersion} WHERE singleton=1;";
        await command.ExecuteNonQueryAsync(cancellationToken);
        return database;
    }

    public async Task ConfigureBackupAsync(
        string repositoryPath,
        bool automaticEnabled,
        TimeSpan interval,
        DateTimeOffset now,
        CancellationToken cancellationToken = default,
        bool pauseDuringGame = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(repositoryPath);
        ValidateBackupInterval(interval);
        var repository = Path.GetFullPath(repositoryPath);
        var firstDue = now.Add(interval);
        await using var connection = await OpenAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            var current = await TryReadControlAsync(
                connection, transaction, cancellationToken);
            // Consume state transitions first: a pending stop must win over settings.
            var applied = current is not null && await ApplyPendingCommandsAsync(
                connection, transaction, current, now, cancellationToken);
            if (applied) current = await TryReadControlAsync(connection, transaction, cancellationToken);
            var runtimeChanged = await ConfigureRuntimeCoreAsync(connection, transaction, pauseDuringGame, cancellationToken);
            var changed = runtimeChanged || current is null
                || !StringComparer.OrdinalIgnoreCase.Equals(
                    current.RepositoryPath, repository)
                || current.AutomaticEnabled != automaticEnabled
                || current.Interval != interval;
            if (current is null)
            {
                await using var insert = connection.CreateCommand();
                insert.Transaction = transaction;
                insert.CommandText =
                    """
                    INSERT INTO backup_scheduler_control VALUES(
                        1,$repository,$enabled,$interval,NULL,NULL,NULL,
                        'Paused',0,0,$due,NULL,NULL);
                    """;
                insert.Parameters.AddWithValue("$repository", repository);
                insert.Parameters.AddWithValue("$enabled", automaticEnabled ? 1 : 0);
                insert.Parameters.AddWithValue(
                    "$interval", checked((long)interval.TotalMinutes));
                insert.Parameters.AddWithValue("$due", firstDue.ToString("O"));
                await insert.ExecuteNonQueryAsync(cancellationToken);
            }
            else if (changed)
            {
                await using var update = connection.CreateCommand();
                update.Transaction = transaction;
                update.CommandText =
                    """
                    UPDATE backup_scheduler_control
                    SET repository_path=$repository,
                        automatic_enabled=$enabled,
                        interval_minutes=$interval,
                        mode=CASE WHEN mode='Limited' THEN 'Paused' ELSE mode END,
                        current_save_id=CASE WHEN mode='Limited' THEN NULL ELSE current_save_id END,
                        current_source_key=CASE WHEN mode='Limited' THEN NULL ELSE current_source_key END,
                        current_source_path=CASE WHEN mode='Limited' THEN NULL ELSE current_source_path END,
                        attempts_remaining=0,
                        generation=generation+1,
                        next_due_utc=CASE WHEN $enabled=1 THEN $due ELSE next_due_utc END
                    WHERE singleton=1;
                    """;
                update.Parameters.AddWithValue("$repository", repository);
                update.Parameters.AddWithValue("$enabled", automaticEnabled ? 1 : 0);
                update.Parameters.AddWithValue(
                    "$interval", checked((long)interval.TotalMinutes));
                update.Parameters.AddWithValue("$due", firstDue.ToString("O"));
                await update.ExecuteNonQueryAsync(cancellationToken);
                if (!automaticEnabled)
                {
                    await using var clear = connection.CreateCommand();
                    clear.Transaction = transaction;
                    clear.CommandText = "DELETE FROM pending_backup_runs;";
                    await clear.ExecuteNonQueryAsync(cancellationToken);
                }
            }

            if (changed || applied)
                await IncrementRevisionAsync(connection, transaction, cancellationToken);
            transaction.Commit();
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    public async Task RestartPeriodicScheduleAsync(
        DateTimeOffset now,
        CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        var current = await TryReadControlAsync(connection, transaction, cancellationToken);
        if (current is { AutomaticEnabled: true, Mode: SchedulerMode.Continuous })
        {
            await using var update = connection.CreateCommand();
            update.Transaction = transaction;
            update.CommandText =
                """
                UPDATE backup_scheduler_control
                SET next_due_utc=$due,generation=generation+1
                WHERE singleton=1;
                """;
            update.Parameters.AddWithValue("$due", now.Add(current.Interval).ToString("O"));
            await update.ExecuteNonQueryAsync(cancellationToken);
            await IncrementRevisionAsync(connection, transaction, cancellationToken);
        }
        transaction.Commit();
    }

    public async Task EnqueueTargetCommandAsync(
        BackupTargetCommand command,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(command);
        command.Validate();
        await using var connection = await OpenAsync(cancellationToken);
        await using var insert = connection.CreateCommand();
        insert.CommandText =
            """
            INSERT OR IGNORE INTO backup_target_commands(
                idempotency_key,command,save_id,source_key,source_path,
                transition_id,cause_run_index,received_utc,applied_utc)
            VALUES($key,$command,$save,$source,$path,$transition,$run,$received,NULL);
            """;
        insert.Parameters.AddWithValue("$key", command.IdempotencyKey);
        insert.Parameters.AddWithValue("$command", command.Kind.ToString());
        insert.Parameters.AddWithValue("$save", command.Target.SaveId);
        insert.Parameters.AddWithValue("$source", command.Target.SourceKey);
        insert.Parameters.AddWithValue(
            "$path", Path.GetFullPath(command.Target.SourcePath));
        insert.Parameters.AddWithValue(
            "$transition", (object?)command.TransitionId ?? DBNull.Value);
        insert.Parameters.AddWithValue(
            "$run", (object?)command.CauseRunIndex ?? DBNull.Value);
        insert.Parameters.AddWithValue("$received", DateTimeOffset.UtcNow.ToString("O"));
        await insert.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task<BackupTickAdmission?> PrepareBackupTickAsync(
        DateTimeOffset now,
        CancellationToken cancellationToken = default,
        TimeSpan? preparationLead = null)
    {
        var lead = ValidateLead(preparationLead);
        await using var connection = await OpenAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            var admission = await PrepareBackupTickCoreAsync(connection, transaction, now, lead, cancellationToken);
            transaction.Commit();
            return admission;
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    /// <summary>
    /// What a runtime-scheduled tick reads, on one connection: the runtime schedule, the prepared tick
    /// and the control state after it, in that order. The scheduler asks every second, also while idle.
    /// </summary>
    public async Task<(RuntimeScheduleStorage Storage, BackupTickAdmission? Admission, BackupSchedulerState Control)>
        PrepareRuntimeTickAsync(DateTimeOffset now, TimeSpan preparationLead, CancellationToken cancellationToken = default)
    {
        var lead = ValidateLead(preparationLead);
        await using var connection = await OpenAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            var storage = await ReadRuntimeScheduleCoreAsync(connection, transaction, cancellationToken);
            var admission = await PrepareBackupTickCoreAsync(connection, transaction, now, lead, cancellationToken);
            var control = await ReadBackupStateCoreAsync(connection, transaction, cancellationToken);
            transaction.Commit();
            return (storage, admission, control);
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    private static TimeSpan ValidateLead(TimeSpan? preparationLead)
    {
        var lead = preparationLead ?? TimeSpan.Zero;
        if (lead < TimeSpan.Zero || lead > TimeSpan.FromSeconds(30))
            throw new ArgumentOutOfRangeException(nameof(preparationLead));
        return lead;
    }

    private static async Task<BackupTickAdmission?> PrepareBackupTickCoreAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        DateTimeOffset now,
        TimeSpan lead,
        CancellationToken cancellationToken)
    {
        var control = await TryReadControlAsync(
            connection, transaction, cancellationToken)
            ?? throw new InvalidOperationException(
                "The backup scheduler has not been configured.");
        var changed = await ApplyPendingCommandsAsync(
            connection, transaction, control, now, cancellationToken);
        if (changed)
        {
            await IncrementRevisionAsync(connection, transaction, cancellationToken);
            control = (await TryReadControlAsync(
                connection, transaction, cancellationToken))!;
        }

        if (!control.AutomaticEnabled || control.Mode == SchedulerMode.Ambiguous)
            return null;

        await using (var retireFinal = connection.CreateCommand())
        {
            retireFinal.Transaction = transaction;
            retireFinal.CommandText = "DELETE FROM pending_backup_runs WHERE kind='Final' OR (kind='RunOnce' AND pending_id GLOB 'state-transition:*');";
            if (await retireFinal.ExecuteNonQueryAsync(cancellationToken) > 0)
                await IncrementRevisionAsync(connection, transaction, cancellationToken);
        }
        var pending = await ReadFirstPendingAsync(
            connection, transaction, cancellationToken);
        if (pending is not null)
        {
            PzTools.Process.Contracts.GameRuntime.RuntimeSaveTicket? deathTicket = null;
            if (pending.PendingId.StartsWith(RuntimeDeathPolicy.Prefix, StringComparison.Ordinal))
            {
                deathTicket = await ReadDeathTicketAsync(connection, transaction, pending.PendingId, pending.Target.SourcePath, cancellationToken);
                if (deathTicket is null)
                {
                    await using var retire = connection.CreateCommand(); retire.Transaction = transaction;
                    retire.CommandText = "DELETE FROM pending_backup_runs WHERE pending_id=$id;";
                    retire.Parameters.AddWithValue("$id", pending.PendingId); await retire.ExecuteNonQueryAsync(cancellationToken);
                    await IncrementRevisionAsync(connection, transaction, cancellationToken);
                    return null;
                }
            }
            return new BackupTickAdmission(
                $"backup-scheduler:pending:{pending.PendingId}:{pending.AttemptSequence}",
                pending.Kind,
                pending.Target,
                control.RepositoryPath,
                pending.EnqueuedUtc,
                control.Generation,
                pending.PendingId, deathTicket);
        }

        if (await RuntimeEnabledAsync(connection, transaction, cancellationToken)
            || control.Mode != SchedulerMode.Continuous
            || control.CurrentTarget is null
            || control.NextDueUtc > now + lead)
            return null;

        return new BackupTickAdmission(
            // Busy 재시도는 새 workflow를 쓰되, 완료 후 상태 확정 전 재시작은 같은 admission을 복구합니다.
            control.PeriodicAdmissionId,
            BackupAdmissionKind.Periodic,
            control.CurrentTarget,
            control.RepositoryPath,
            control.NextDueUtc,
            control.Generation,
            PendingCommandId: null);
    }

    public async Task FinishBackupTickAsync(
        BackupTickAdmission admission,
        bool workerStarted,
        long? runIndex,
        ProcessOutcome outcome,
        DateTimeOffset now,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(admission);
        await using var connection = await OpenAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            var control = await TryReadControlAsync(
                connection, transaction, cancellationToken)
                ?? throw new InvalidOperationException(
                    "The backup scheduler has not been configured.");
            var changed = false;
            if (admission.PendingCommandId is not null)
            {
                await using var pending = connection.CreateCommand();
                pending.Transaction = transaction;
                if (workerStarted && !(admission.RuntimeTicket is { IsDeath: true } && outcome == ProcessOutcome.Skipped))
                {
                    pending.CommandText =
                        "DELETE FROM pending_backup_runs WHERE pending_id=$id;";
                }
                else
                {
                    pending.CommandText =
                        "UPDATE pending_backup_runs SET attempt_sequence=attempt_sequence+1 "
                        + "WHERE pending_id=$id;";
                }
                pending.Parameters.AddWithValue("$id", admission.PendingCommandId);
                changed |= await pending.ExecuteNonQueryAsync(cancellationToken) != 0;

                if (workerStarted
                    && control.Generation == admission.Generation
                    && control.Mode == SchedulerMode.Limited
                    && control.CurrentTarget is not null
                    && SameTarget(control.CurrentTarget, admission.Target))
                {
                    await using var clear = connection.CreateCommand();
                    clear.Transaction = transaction;
                    clear.CommandText =
                        """
                        UPDATE backup_scheduler_control
                        SET current_save_id=NULL,current_source_key=NULL,
                            current_source_path=NULL,mode='Paused',attempts_remaining=0,
                            generation=generation+1
                        WHERE singleton=1;
                        """;
                    await clear.ExecuteNonQueryAsync(cancellationToken);
                    changed = true;
                }
            }
            else if (admission.RuntimeTicket is null && control.Generation == admission.Generation)
            {
                // A completed old admission must not overwrite a newer interval,
                // disabled schedule, or target selected while its worker was running.
                // 점검기가 저장소를 사용해 백업 worker를 시작하지 못했다면 예정 틱을 유지해 재시도합니다.
                if (workerStarted || outcome != ProcessOutcome.Busy)
                {
                    var due = BackupScheduleTiming.NextDue(admission.ScheduledUtc, control.Interval, now);
                    await using var advance = connection.CreateCommand();
                    advance.Transaction = transaction;
                    advance.CommandText =
                        "UPDATE backup_scheduler_control SET next_due_utc=$due WHERE singleton=1;";
                    advance.Parameters.AddWithValue("$due", due.ToString("O"));
                    await advance.ExecuteNonQueryAsync(cancellationToken);
                    changed = true;
                }
            }

            if (runIndex is not null)
            {
                await using var result = connection.CreateCommand();
                result.Transaction = transaction;
                result.CommandText =
                    "UPDATE backup_scheduler_control SET last_run_index=$run,last_outcome=$outcome "
                    + "WHERE singleton=1;";
                result.Parameters.AddWithValue("$run", runIndex.Value);
                result.Parameters.AddWithValue("$outcome", outcome.ToString());
                await result.ExecuteNonQueryAsync(cancellationToken);
                changed = true;
            }

            if (changed)
                await IncrementRevisionAsync(connection, transaction, cancellationToken);
            transaction.Commit();
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    // Opt-in, for a process that reads this database every second for as long as it runs (the app's
    // projections). A connection per read made SQLite create the -wal and -shm files on open and delete
    // them when the last connection closed, every second, each time also scanned by file-system filters.
    // Reads still use short transactions, so writers and checkpoints are never held up.
    private readonly SemaphoreSlim heldGate = new(1, 1);
    private SqliteConnection? heldReader;
    private bool holdReader;

    public void HoldReadConnection() => holdReader = true;

    public void ReleaseReadConnection()
    {
        heldGate.Wait();
        try
        {
            holdReader = false;
            heldReader?.Dispose();
            heldReader = null;
        }
        finally { heldGate.Release(); }
    }

    private async Task<T> ReadAsync<T>(Func<SqliteConnection, Task<T>> read, CancellationToken cancellationToken)
    {
        if (!holdReader)
        {
            await using var connection = await OpenAsync(cancellationToken);
            return await read(connection);
        }
        await heldGate.WaitAsync(cancellationToken);
        try
        {
            heldReader ??= await OpenAsync(cancellationToken);
            try { return await read(heldReader); }
            catch
            {
                // Whatever failed, the next read starts from a fresh connection.
                heldReader.Dispose();
                heldReader = null;
                throw;
            }
        }
        finally { heldGate.Release(); }
    }

    public Task<BackupSchedulerState> ReadBackupStateIfChangedAsync(
        long lastSeenRevision,
        CancellationToken cancellationToken = default) =>
        ReadAsync(connection => ReadBackupStateIfChangedAsync(connection, lastSeenRevision, cancellationToken), cancellationToken);

    private static async Task<BackupSchedulerState> ReadBackupStateIfChangedAsync(
        SqliteConnection connection,
        long lastSeenRevision,
        CancellationToken cancellationToken)
    {
        // Only reads: a deferred transaction gives a consistent snapshot without taking the write
        // lock that the schedulers and the app would otherwise wait on every second.
        using var transaction = connection.BeginTransaction(deferred: true);
        var revision = await ReadRevisionAsync(connection, transaction, cancellationToken);
        if (revision == lastSeenRevision)
        {
            transaction.Commit();
            return new BackupSchedulerState(
                false, revision, "", false, TimeSpan.FromMinutes(1), null,
                SchedulerMode.Paused, 0, 0, 0, DateTimeOffset.MinValue, null, null);
        }
        var state = await ReadBackupStateCoreAsync(connection, transaction, cancellationToken, revision);
        transaction.Commit();
        return state;
    }

    private static async Task<BackupSchedulerState> ReadBackupStateCoreAsync(
        SqliteConnection connection, SqliteTransaction transaction, CancellationToken cancellationToken,
        long? revision = null)
    {
        var state = await TryReadControlAsync(connection, transaction, cancellationToken)
            ?? throw new InvalidOperationException(
                "The backup scheduler has not been configured.");
        var pending = await CountPendingAsync(connection, transaction, cancellationToken);
        return state with
        {
            Modified = true,
            SchedulerRevision = revision ?? await ReadRevisionAsync(connection, transaction, cancellationToken),
            PendingRuns = pending,
        };
    }

    public async Task<bool> PrepareStateTickAsync(
        TimeSpan interval,
        DateTimeOffset now,
        CancellationToken cancellationToken = default)
    {
        ValidateStateInterval(interval);
        await using var connection = await OpenAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        await using (var ensure = connection.CreateCommand())
        {
            ensure.Transaction = transaction;
            ensure.CommandText =
                "INSERT OR IGNORE INTO state_scheduler VALUES(1,$interval,$due,1);";
            ensure.Parameters.AddWithValue(
                "$interval", checked((long)interval.TotalSeconds));
            ensure.Parameters.AddWithValue("$due", now.ToString("O"));
            await ensure.ExecuteNonQueryAsync(cancellationToken);
        }
        long storedInterval;
        DateTimeOffset due;
        await using (var dueCheck = connection.CreateCommand())
        {
            dueCheck.Transaction = transaction;
            dueCheck.CommandText =
                "SELECT interval_seconds,next_due_utc FROM state_scheduler WHERE singleton=1;";
            await using var reader = await dueCheck.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
                throw new InvalidOperationException("The state scheduler has not been configured.");
            storedInterval = reader.GetInt64(0);
            due = DateTimeOffset.Parse(reader.GetString(1), CultureInfo.InvariantCulture);
        }
        if (storedInterval != checked((long)interval.TotalSeconds))
        {
            // A changed polling interval takes effect on the first tick after restart.
            due = now;
            await using var update = connection.CreateCommand();
            update.Transaction = transaction;
            update.CommandText =
                "UPDATE state_scheduler SET interval_seconds=$interval,next_due_utc=$due "
                + "WHERE singleton=1;";
            update.Parameters.AddWithValue("$interval", checked((long)interval.TotalSeconds));
            update.Parameters.AddWithValue("$due", due.ToString("O"));
            await update.ExecuteNonQueryAsync(cancellationToken);
        }
        transaction.Commit();
        // A due time is never more than one interval ahead. Further means the clock was set back:
        // check now rather than stopping state checks until the old time comes round again.
        return due <= now || due > now.Add(interval);
    }

    public async Task AdvanceStateDueAsync(
        TimeSpan interval,
        DateTimeOffset now,
        CancellationToken cancellationToken = default)
    {
        ValidateStateInterval(interval);
        await using var connection = await OpenAsync(cancellationToken);
        await using var read = connection.CreateCommand();
        read.CommandText =
            "SELECT next_due_utc FROM state_scheduler WHERE singleton=1;";
        var value = (string?)await read.ExecuteScalarAsync(cancellationToken)
            ?? now.ToString("O");
        var due = DateTimeOffset.Parse(value, CultureInfo.InvariantCulture).Add(interval);
        // After sleep, a clock change or a long stop, start a fresh interval instead of stepping
        // through every missed one (or keeping a time the clock has been set back from).
        if (due <= now || due > now.Add(interval)) due = now.Add(interval);
        await using var update = connection.CreateCommand();
        update.CommandText =
            "UPDATE state_scheduler SET interval_seconds=$interval,next_due_utc=$due "
            + "WHERE singleton=1;";
        update.Parameters.AddWithValue(
            "$interval", checked((long)interval.TotalSeconds));
        update.Parameters.AddWithValue("$due", due.ToString("O"));
        await update.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async Task<bool> ApplyPendingCommandsAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        BackupSchedulerState control,
        DateTimeOffset now,
        CancellationToken token)
    {
        var commands = new List<BackupTargetCommand>();
        await using (var read = connection.CreateCommand())
        {
            read.Transaction = transaction;
            read.CommandText =
                """
                SELECT idempotency_key,command,save_id,source_key,source_path,
                       transition_id,cause_run_index
                FROM backup_target_commands
                WHERE applied_utc IS NULL ORDER BY received_utc,idempotency_key;
                """;
            await using var reader = await read.ExecuteReaderAsync(token);
            while (await reader.ReadAsync(token))
            {
                commands.Add(new BackupTargetCommand(
                    reader.GetString(0),
                    Enum.Parse<BackupTargetCommandKind>(reader.GetString(1)),
                    new BackupTarget(
                        reader.GetString(2), reader.GetString(3), reader.GetString(4)),
                    reader.IsDBNull(5) ? null : reader.GetString(5),
                    reader.IsDBNull(6) ? null : reader.GetInt64(6)));
            }
        }

        if (commands.Count == 0) return false;
        var target = control.CurrentTarget;
        var mode = control.Mode;
        var attempts = control.AttemptsRemaining;
        var nextDue = control.NextDueUtc;
        var changed = false;
        var runtimeMode = await RuntimeEnabledAsync(connection, transaction, token);
        foreach (var command in commands)
        {
            if (command.Kind == BackupTargetCommandKind.RunOnceNow && command.IdempotencyKey.StartsWith("state-transition:", StringComparison.Ordinal)) continue;
            // Weak file-lock transitions may not overwrite authenticated runtime authority.
            var actionable = !runtimeMode || command.Kind == BackupTargetCommandKind.RunOnceNow
                && target is not null && SameTarget(target, command.Target);
            if (actionable) switch (command.Kind)
            {
                case BackupTargetCommandKind.ActivateTarget:
                    target = command.Target;
                    // Activity and the user's enable switch are separate authorities.
                    mode = SchedulerMode.Continuous;
                    attempts = 0;
                    nextDue = now.Add(control.Interval);
                    changed = true;
                    break;

                // Retired exit commands are stops, never a one-off backup trigger.
                case BackupTargetCommandKind.FinalizeTarget:
                case BackupTargetCommandKind.ClearTarget:
                    if (target is not null && SameTarget(target, command.Target))
                    {
                        target = null;
                        mode = SchedulerMode.Paused;
                        attempts = 0;
                        changed = true;
                    }
                    changed |= await DeletePendingForTargetAsync(
                        connection, transaction, command.Target.SaveId, token) > 0;
                    break;

                case BackupTargetCommandKind.RunOnceNow:
                    if (control.AutomaticEnabled)
                    {
                        await InsertPendingAsync(
                            connection, transaction, command,
                            BackupAdmissionKind.RunOnce, token);
                        changed = true;
                    }
                    break;

                case BackupTargetCommandKind.SuspendAmbiguous:
                    if (mode != SchedulerMode.Ambiguous || attempts != 0)
                    {
                        mode = SchedulerMode.Ambiguous;
                        attempts = 0;
                        changed = true;
                    }
                    break;
            }
        }

        if (changed)
        {
            await using var update = connection.CreateCommand();
            update.Transaction = transaction;
            update.CommandText =
                """
                UPDATE backup_scheduler_control
                SET current_save_id=$save,current_source_key=$source,
                    current_source_path=$path,mode=$mode,
                    attempts_remaining=$attempts,generation=generation+$generationStep,
                    next_due_utc=$due
                WHERE singleton=1;
                """;
            update.Parameters.AddWithValue(
                "$save", (object?)target?.SaveId ?? DBNull.Value);
            update.Parameters.AddWithValue(
                "$source", (object?)target?.SourceKey ?? DBNull.Value);
            update.Parameters.AddWithValue(
                "$path", (object?)target?.SourcePath ?? DBNull.Value);
            update.Parameters.AddWithValue("$mode", mode.ToString());
            update.Parameters.AddWithValue("$generationStep", runtimeMode ? 0 : 1);
            update.Parameters.AddWithValue("$attempts", attempts);
            update.Parameters.AddWithValue("$due", nextDue.ToString("O"));
            await update.ExecuteNonQueryAsync(token);
        }

        await using (var applied = connection.CreateCommand())
        {
            applied.Transaction = transaction;
            applied.CommandText =
                "UPDATE backup_target_commands SET applied_utc=$now "
                + "WHERE applied_utc IS NULL;";
            applied.Parameters.AddWithValue("$now", now.ToString("O"));
            await applied.ExecuteNonQueryAsync(token);
        }
        return changed;
    }

    private static async Task MigrateAmbiguousModeAsync(
        SqliteConnection connection,
        CancellationToken cancellationToken)
    {
        await using var inspect = connection.CreateCommand();
        inspect.CommandText =
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='backup_target_commands';";
        var sql = Convert.ToString(await inspect.ExecuteScalarAsync(cancellationToken),
            CultureInfo.InvariantCulture) ?? string.Empty;
        if (sql.Contains("SuspendAmbiguous", StringComparison.Ordinal)) return;

        await using var migration = connection.CreateCommand();
        migration.CommandText =
            """
            BEGIN IMMEDIATE;
            ALTER TABLE backup_scheduler_control RENAME TO backup_scheduler_control_v3;
            CREATE TABLE backup_scheduler_control(
                singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                repository_path TEXT NOT NULL,
                automatic_enabled INTEGER NOT NULL CHECK(automatic_enabled IN (0,1)),
                interval_minutes INTEGER NOT NULL CHECK(interval_minutes BETWEEN 1 AND 60),
                current_save_id TEXT NULL,
                current_source_key TEXT NULL,
                current_source_path TEXT NULL,
                mode TEXT NOT NULL CHECK(mode IN ('Paused','Continuous','Limited','Ambiguous')),
                attempts_remaining INTEGER NOT NULL,
                generation INTEGER NOT NULL,
                next_due_utc TEXT NOT NULL,
                last_run_index INTEGER NULL,
                last_outcome TEXT NULL
            ) STRICT;
            INSERT INTO backup_scheduler_control SELECT * FROM backup_scheduler_control_v3;
            DROP TABLE backup_scheduler_control_v3;

            ALTER TABLE backup_target_commands RENAME TO backup_target_commands_v3;
            CREATE TABLE backup_target_commands(
                idempotency_key TEXT PRIMARY KEY,
                command TEXT NOT NULL CHECK(command IN(
                    'ActivateTarget','FinalizeTarget','ClearTarget','RunOnceNow','SuspendAmbiguous')),
                save_id TEXT NOT NULL,
                source_key TEXT NOT NULL,
                source_path TEXT NOT NULL,
                transition_id TEXT NULL,
                cause_run_index INTEGER NULL,
                received_utc TEXT NOT NULL,
                applied_utc TEXT NULL
            ) STRICT;
            INSERT INTO backup_target_commands SELECT * FROM backup_target_commands_v3;
            DROP TABLE backup_target_commands_v3;
            COMMIT;
            """;
        await migration.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async Task InsertPendingAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        BackupTargetCommand command,
        BackupAdmissionKind kind,
        CancellationToken token)
    {
        await using var insert = connection.CreateCommand();
        insert.Transaction = transaction;
        insert.CommandText =
            """
            INSERT OR IGNORE INTO pending_backup_runs(
                pending_id,kind,save_id,source_key,source_path,attempt_sequence,enqueued_utc)
            VALUES($id,$kind,$save,$source,$path,1,$utc);
            """;
        insert.Parameters.AddWithValue("$id", command.IdempotencyKey);
        insert.Parameters.AddWithValue("$kind", kind.ToString());
        insert.Parameters.AddWithValue("$save", command.Target.SaveId);
        insert.Parameters.AddWithValue("$source", command.Target.SourceKey);
        insert.Parameters.AddWithValue("$path", command.Target.SourcePath);
        insert.Parameters.AddWithValue("$utc", DateTimeOffset.UtcNow.ToString("O"));
        await insert.ExecuteNonQueryAsync(token);
    }

    private static async Task<int> DeletePendingForTargetAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string saveId,
        CancellationToken token)
    {
        await using var delete = connection.CreateCommand();
        delete.Transaction = transaction;
        delete.CommandText =
            "DELETE FROM pending_backup_runs WHERE save_id=$save;";
        delete.Parameters.AddWithValue("$save", saveId);
        return await delete.ExecuteNonQueryAsync(token);
    }

    private static async Task<PendingRun?> ReadFirstPendingAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        CancellationToken token)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            SELECT pending_id,kind,save_id,source_key,source_path,
                   attempt_sequence,enqueued_utc
            FROM pending_backup_runs ORDER BY enqueued_utc,pending_id LIMIT 1;
            """;
        await using var reader = await command.ExecuteReaderAsync(token);
        if (!await reader.ReadAsync(token)) return null;
        return new PendingRun(
            reader.GetString(0),
            Enum.Parse<BackupAdmissionKind>(reader.GetString(1)),
            new BackupTarget(reader.GetString(2), reader.GetString(3), reader.GetString(4)),
            reader.GetInt64(5),
            DateTimeOffset.Parse(reader.GetString(6), CultureInfo.InvariantCulture));
    }

    private static async Task<BackupSchedulerState?> TryReadControlAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        CancellationToken token)
    {
        var revision = await ReadRevisionAsync(connection, transaction, token);
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            SELECT repository_path,automatic_enabled,interval_minutes,
                   current_save_id,current_source_key,current_source_path,
                   mode,attempts_remaining,generation,next_due_utc,
                   last_run_index,last_outcome
            FROM backup_scheduler_control WHERE singleton=1;
            """;
        await using var reader = await command.ExecuteReaderAsync(token);
        if (!await reader.ReadAsync(token)) return null;
        var target = reader.IsDBNull(3)
            ? null
            : new BackupTarget(
                reader.GetString(3), reader.GetString(4), reader.GetString(5));
        return new BackupSchedulerState(
            true,
            revision,
            reader.GetString(0),
            reader.GetInt64(1) != 0,
            TimeSpan.FromMinutes(reader.GetInt64(2)),
            target,
            Enum.Parse<SchedulerMode>(reader.GetString(6)),
            reader.GetInt32(7),
            PendingRuns: 0,
            reader.GetInt64(8),
            DateTimeOffset.Parse(reader.GetString(9), CultureInfo.InvariantCulture),
            reader.IsDBNull(10) ? null : reader.GetInt64(10),
            reader.IsDBNull(11)
                ? null : Enum.Parse<ProcessOutcome>(reader.GetString(11)));
    }

    private static async Task<int> CountPendingAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        CancellationToken token)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT COUNT(*) FROM pending_backup_runs;";
        return Convert.ToInt32(
            await command.ExecuteScalarAsync(token), CultureInfo.InvariantCulture);
    }

    private static async Task<long> ReadRevisionAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        CancellationToken token)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            "SELECT scheduler_revision FROM scheduler_info WHERE singleton=1;";
        return Convert.ToInt64(
            await command.ExecuteScalarAsync(token), CultureInfo.InvariantCulture);
    }

    private static async Task IncrementRevisionAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        CancellationToken token)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            "UPDATE scheduler_info SET scheduler_revision=scheduler_revision+1 "
            + "WHERE singleton=1;";
        await command.ExecuteNonQueryAsync(token);
    }

    private static bool SameTarget(BackupTarget left, BackupTarget right) =>
        StringComparer.OrdinalIgnoreCase.Equals(left.SaveId, right.SaveId);

    private static void ValidateBackupInterval(TimeSpan interval)
    {
        if (interval < TimeSpan.FromMinutes(1)
            || interval > TimeSpan.FromMinutes(60)
            || interval.Ticks % TimeSpan.TicksPerMinute != 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(interval), "The backup interval must be 1 to 60 whole minutes.");
        }
    }

    private static void ValidateStateInterval(TimeSpan interval)
    {
        if (interval < TimeSpan.FromSeconds(1)
            || interval.Ticks % TimeSpan.TicksPerSecond != 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(interval),
                "The state scheduler interval must be a whole number of seconds.");
        }
    }

    private Task<SqliteConnection> OpenAsync(CancellationToken token) =>
        OpenConfiguredAsync(new SqliteConnection(connectionString), token);

    // Own the native handle until every configuration statement succeeds.
    // The caller cannot dispose a connection that was never returned.
    private static async Task<SqliteConnection> OpenConfiguredAsync(
        SqliteConnection connection, CancellationToken token)
    {
        try
        {
            await connection.OpenAsync(token);
            await using var command = connection.CreateCommand();
            command.CommandText =
                "PRAGMA foreign_keys=ON; PRAGMA busy_timeout=1000; PRAGMA journal_mode=WAL;";
            await command.ExecuteNonQueryAsync(token);
            return connection;
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }

    private sealed record PendingRun(
        string PendingId,
        BackupAdmissionKind Kind,
        BackupTarget Target,
        long AttemptSequence,
        DateTimeOffset EnqueuedUtc);
}
