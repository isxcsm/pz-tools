-- Work cut into slices, for the breaker box window's refresh: a job is a list of tasks run a few milliseconds a frame,
-- so that what a window does when something changed (rows, status line, plan) never takes one frame long. A task is a
-- function(deadline, job) that does its work and returns true, or, past the deadline with more to do, false (it is
-- called again the next frame where it left off). The deadline is a getTimestampMs time; none (nil) runs to the end.
require "BuildingUtilities/Core"
local BU = BuildingUtilities
local Job = {}
BU.Job = Job

function Job.new(tasks) return { tasks = tasks or {}, i = 1 } end

-- Tasks to run right after the one running, before the rest.
function Job.insert(job, tasks)
    for k, task in ipairs(tasks) do table.insert(job.tasks, job.i + k, task) end
end

-- The rest of the job dropped (its window closed or opened anew).
function Job.stop(job) job.i = #job.tasks + 1 end

-- Runs tasks until the job is done or the deadline has passed; true when it is done. A task that is under way when the
-- deadline passes finishes its item first: slices are as long as the longest item.
function Job.run(job, deadline)
    local tasks = job.tasks
    while job.i <= #tasks do
        if tasks[job.i](deadline, job) ~= false then job.i = job.i + 1 end
        if deadline and job.i <= #tasks and getTimestampMs() >= deadline then return false end
    end
    return true
end

-- All of a list of tasks at once.
function Job.runAll(tasks) Job.run(Job.new(tasks), nil) end

-- A task over a list: fn(item, index) for each item, as many as the slice has time for. The list is given by a
-- function, asked when the task starts (an earlier task may be the one that makes it).
function Job.each(listOf, fn)
    local list, i
    return function(deadline)
        if not list then list, i = listOf(), 0 end
        while i < #list do
            i = i + 1
            fn(list[i], i)
            if deadline and i < #list and getTimestampMs() >= deadline then return false end
        end
        return true
    end
end

return Job
