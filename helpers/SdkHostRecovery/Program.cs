using System;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;

internal static class SdkHostRecovery
{
    private const string Key = "db/sdk/develop/ip";

    [DllImport("libvconf.so.0")]
    private static extern IntPtr vconf_get_str(string key);

    [DllImport("libvconf.so.0")]
    private static extern int vconf_set_str(string key, string value);

    [DllImport("libc.so.6")]
    private static extern void free(IntPtr ptr);

    [DllImport("libc.so.6")]
    private static extern uint getuid();

    private static string Read()
    {
        IntPtr p = vconf_get_str(Key);
        if (p == IntPtr.Zero)
        {
            throw new InvalidOperationException("Host unavailable");
        }
        try
        {
            return Marshal.PtrToStringAnsi(p);
        }
        finally
        {
            free(p);
        }
    }

    private static bool ValidHost(string h)
    {
        return IPAddress.TryParse(h, out IPAddress ip) &&
               ip.AddressFamily == AddressFamily.InterNetwork &&
               ip.ToString() == h &&
               h != "0.0.0.0";
    }

    public static int Main(string[] args)
    {
        try
        {
            if (getuid() != 0 || args.Length != 4 || !ValidHost(args[1]) || !ValidHost(args[2]))
            {
                return 2;
            }
            if (!int.TryParse(args[3], out int seconds) || seconds < 0 || seconds > 600)
            {
                return 2;
            }
            if (args[0] == "watch")
            {
                if (seconds < 30) return 2;
                Thread.Sleep(seconds * 1000);
            }
            else if (args[0] != "set" || seconds != 0)
            {
                return 2;
            }

            string current = Read();
            if (current == args[2])
            {
                Console.WriteLine("Already restored");
                return 0;
            }
            if (current != args[1])
            {
                throw new InvalidOperationException("Host drift; refusing overwrite");
            }
            if (vconf_set_str(Key, args[2]) != 0 || Read() != args[2])
            {
                throw new InvalidOperationException("Host change unconfirmed");
            }
            Console.WriteLine("Host readback verified");
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine(e.Message);
            return 1;
        }
    }
}
