using System;
using System.Runtime.InteropServices;

internal static class FeatureControl
{
    private static readonly string[] BoolKeys =
    {
        "uifw.support_animation",
        "eden.hide_animation_support",
        "service.adagent_enable",
        "multiview.eden_preview_support",
        "hbbtv.enable_atsc_ic",
        "product.tvplus_support",
        "eden.tvplus_autorun",
        "eden.tvplus_autorun_already_support",
        "voice.voice_recognition_support",
        "function_osd.support_voice_recognize",
        "connectionguide.apple_airplay_support",
        "setting.menuitem.autorun_multiview_mirroring_support",
        "iotframework.client",
        "multiview.iot_cam"
    };

    private static readonly (string Key, int DisabledValue, int DefaultValue)[] IntKeys =
    {
        ("broswer_preloading", 0, 2)
    };

    [DllImport("libfconfig.so", CallingConvention = CallingConvention.Cdecl)]
    private static extern int fconfig_get_bool(string key, out byte value);

    [DllImport("libfconfig.so", CallingConvention = CallingConvention.Cdecl)]
    private static extern int fconfig_set_bool(string key, byte value);

    [DllImport("libfconfig.so", CallingConvention = CallingConvention.Cdecl)]
    private static extern int fconfig_get_value_int(string key, out int value);

    [DllImport("libfconfig.so", CallingConvention = CallingConvention.Cdecl)]
    private static extern int fconfig_set_value_int(string key, int value);

    public static int Main(string[] args)
    {
        if (args.Length != 1 || (args[0] != "inspect" && args[0] != "disable" && args[0] != "restore"))
        {
            Console.Error.WriteLine("usage: FeatureControl.dll <inspect|disable|restore>");
            return 1;
        }

        string mode = args[0];
        int failures = 0;

        foreach (string suffix in BoolKeys)
        {
            string fullKey = "com.samsung/featureconf/" + suffix;
            int r = fconfig_get_bool(fullKey, out byte before);
            Console.WriteLine(fullKey + " read=" + r + " before=" + before);
            if (r < 0)
            {
                failures++;
                continue;
            }
            if (mode == "inspect")
            {
                continue;
            }
            byte desired = (byte)(mode == "disable" ? 0 : 1);
            if (before == desired)
            {
                continue;
            }
            r = fconfig_set_bool(fullKey, desired);
            int rr = fconfig_get_bool(fullKey, out byte after);
            Console.WriteLine(fullKey + " set=" + r + " readback=" + rr + " after=" + after);
            if (r < 0 || rr < 0 || after != desired)
            {
                failures++;
            }
        }

        foreach (var item in IntKeys)
        {
            string fullKey = "com.samsung/featureconf/" + item.Key;
            int r = fconfig_get_value_int(fullKey, out int before);
            Console.WriteLine(fullKey + " read=" + r + " before=" + before);
            if (r < 0)
            {
                failures++;
                continue;
            }
            if (mode == "inspect")
            {
                continue;
            }
            int desired = mode == "disable" ? item.DisabledValue : item.DefaultValue;
            if (before == desired)
            {
                continue;
            }
            r = fconfig_set_value_int(fullKey, desired);
            int rr = fconfig_get_value_int(fullKey, out int after);
            Console.WriteLine(fullKey + " set=" + r + " readback=" + rr + " after=" + after);
            if (r < 0 || rr < 0 || after != desired)
            {
                failures++;
            }
        }

        return failures == 0 ? 0 : 2;
    }
}
