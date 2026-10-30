if(-not ('SpectralConsoleHost' -as [type])){
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SpectralConsoleHost {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr handle, int command);
    public static void Hide() { var handle=GetConsoleWindow(); if(handle!=IntPtr.Zero) ShowWindow(handle,0); }
}
"@

}
function Hide-SpectralConsole { [SpectralConsoleHost]::Hide() }
