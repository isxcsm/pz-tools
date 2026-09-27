# 실행 중인 관련 프로세스의 권한 토큰만 조회합니다. 권한·설정·프로세스를 변경하지 않습니다.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class ProcessTokenDiagnostic {
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int id);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr token, int kind, IntPtr data, int length, out int needed);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    static string Flag(IntPtr token, int kind) {
        var data = Marshal.AllocHGlobal(4);
        try {
            int needed;
            return GetTokenInformation(token, kind, data, 4, out needed)
                ? Marshal.ReadInt32(data).ToString() : new Win32Exception().Message;
        } finally { Marshal.FreeHGlobal(data); }
    }
    public static string Read(int id) {
        var process = OpenProcess(0x1000, false, id);
        if(process == IntPtr.Zero) return "OpenProcess: " + new Win32Exception().Message;
        IntPtr token = IntPtr.Zero;
        try {
            if(!OpenProcessToken(process, 8, out token)) return "OpenProcessToken: " + new Win32Exception().Message;
            int size; GetTokenInformation(token, 25, IntPtr.Zero, 0, out size);
            var buffer = Marshal.AllocHGlobal(size);
            try {
                if(!GetTokenInformation(token, 25, buffer, size, out size)) return new Win32Exception().Message;
                var sid = new SecurityIdentifier(Marshal.ReadIntPtr(buffer)).Value;
                return "Integrity=" + sid + "; Elevated=" + Flag(token, 20) + "; UIAccess=" + Flag(token, 26);
            } finally { Marshal.FreeHGlobal(buffer); }
        } finally { if(token != IntPtr.Zero) CloseHandle(token); CloseHandle(process); }
    }
}
'@
Get-Process | Where-Object { $_.ProcessName -match '^(ChatGPT|codex|codex-computer-use-swift|PzTools.App|devenv)$' } |
    ForEach-Object { [pscustomobject]@{ Id=$_.Id; Name=$_.ProcessName; Token=[ProcessTokenDiagnostic]::Read($_.Id) } } |
    Format-Table -AutoSize
