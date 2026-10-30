using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

// Restricted to a validated render endpoint GUID; never accepts a registry path.
// REG_OPTION_BACKUP_RESTORE grants an administrative handle without changing ACLs.
public static class SpectralEndpointRegistry
{
    [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct Privilege { public uint Count; public Luid Id; public uint Attributes; }
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool LookupPrivilegeValue(string system, string name, out Luid id);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref Privilege state, uint size, out Privilege previous, out uint needed);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] static extern int RegCreateKeyEx(IntPtr root, string path, uint reserved, string type, uint options, uint desired, IntPtr security, out SafeRegistryHandle key, out uint disposition);
    static Privilege Enable(IntPtr token, string name)
    {
        Luid id;
        if (!LookupPrivilegeValue(null, name, out id)) throw new Win32Exception(Marshal.GetLastWin32Error());
        Privilege state = new Privilege { Count=1, Id=id, Attributes=2 };
        Privilege previous; uint size;
        if (!AdjustTokenPrivileges(token, false, ref state, (uint)Marshal.SizeOf(typeof(Privilege)), out previous, out size))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        int error = Marshal.GetLastWin32Error();
        if (error != 0) throw new Win32Exception(error, name + " is unavailable. Run elevated PowerShell.");
        return previous;
    }
    static void Restore(IntPtr token, ref Privilege previous)
    {
        Privilege ignored; uint size;
        if (!AdjustTokenPrivileges(token, false, ref previous, (uint)Marshal.SizeOf(typeof(Privilege)), out ignored, out size))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    public static RegistryKey OpenEndpoint(string endpointGuid, bool create)
    {
        if (!Environment.Is64BitProcess) throw new InvalidOperationException("64-bit PowerShell required.");
        Guid parsed;
        if (!Guid.TryParseExact(endpointGuid,"B",out parsed)) throw new ArgumentException("Invalid render endpoint GUID.");
        string parent = @"SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\" + parsed.ToString("B");
        string path = parent + @"\FxProperties";
        using (RegistryKey check = Registry.LocalMachine.OpenSubKey(parent))
            if (check == null) throw new InvalidOperationException("Selected render endpoint is missing.");
        using (RegistryKey check = Registry.LocalMachine.OpenSubKey(path))
            if (check == null && !create) throw new InvalidOperationException("Selected endpoint FxProperties is missing.");
        IntPtr token;
        if (!OpenProcessToken(new IntPtr(-1), 0x28, out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
        Privilege backup = new Privilege(), restore = new Privilege();
        bool haveBackup=false, haveRestore=false;
        SafeRegistryHandle handle=null;
        try
        {
            backup=Enable(token,"SeBackupPrivilege"); haveBackup=true;
            restore=Enable(token,"SeRestorePrivilege"); haveRestore=true;
            uint disposition;
            int error=RegCreateKeyEx(new IntPtr(unchecked((int)0x80000002)),path,0,null,4,0,IntPtr.Zero,out handle,out disposition);
            if (error != 0) throw new Win32Exception(error);
            if (disposition != 2 && !create) throw new InvalidOperationException("Expected existing endpoint key.");
            RegistryKey key=RegistryKey.FromHandle(handle,RegistryView.Registry64);
            handle=null; // RegistryKey owns the SafeRegistryHandle now.
            return key;
        }
        finally
        {
            try { if (haveRestore) Restore(token,ref restore); }
            finally
            {
                try { if (haveBackup) Restore(token,ref backup); }
                finally { if (handle != null) handle.Dispose(); CloseHandle(token); }
            }
        }
    }
}
