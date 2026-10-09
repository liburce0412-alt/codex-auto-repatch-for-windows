using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

public sealed class Win10CaptureTarget : Form
{
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
    private readonly string root;
    private readonly string token;
    private readonly Label banner = new Label();
    private readonly Panel animation = new Panel();
    private readonly TextBox input = new TextBox();
    private readonly Button button = new Button();
    private readonly Timer timer = new Timer();
    private int frame;
    private int clicks;

    private Win10CaptureTarget(string directory, string identifier)
    {
        root = directory;
        token = identifier;
        Text = "Codex Win10 Capture Test " + token;
        ClientSize = new Size(720, 440);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        KeyPreview = true;
        banner.SetBounds(24, 24, 670, 65);
        banner.Font = new Font("Consolas", 15);
        animation.SetBounds(24, 112, 670, 175);
        animation.BackColor = Color.FromArgb(30, 160, 80);
        button.SetBounds(24, 315, 190, 45);
        button.Text = "Test clicks: 0";
        button.Click += delegate { clicks++; button.Text = "Test clicks: " + clicks; };
        input.SetBounds(240, 323, 454, 32);
        input.AccessibleName = "Diagnostic text input";
        Controls.AddRange(new Control[] { banner, animation, button, input });
        KeyDown += delegate(object sender, KeyEventArgs args) {
            if (args.KeyCode == Keys.Escape) Close();
        };
        timer.Interval = 100;
        timer.Tick += delegate {
            if (File.Exists(Path.Combine(root, "animate.flag"))) {
                frame++;
                animation.BackColor = Color.FromArgb(30 + frame % 180, 160, 80);
            }
            banner.Text = "Codex Win10 Capture Test\r\n" + token + "  frame=" + frame;
            SaveState();
        };
        Shown += delegate { timer.Start(); SaveState(); };
        FormClosed += delegate { timer.Stop(); File.WriteAllText(Path.Combine(root, "closed.flag"), ""); };
    }

    private object Center(Control control)
    {
        Point point = control.PointToScreen(new Point(control.Width / 2, control.Height / 2));
        return new { x = point.X - Left, y = point.Y - Top };
    }

    private void SaveState()
    {
        var state = new {
            token = token,
            windowId = Handle.ToInt64(),
            processId = Process.GetCurrentProcess().Id,
            foreground = GetForegroundWindow() == Handle,
            timestamp = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds,
            frame = frame, clicks = clicks, input = input.Text,
            width = Width, height = Height,
            button = Center(button), textbox = Center(input)
        };
        string destination = Path.Combine(root, "target-state.json");
        string temporary = destination + ".tmp";
        File.WriteAllText(temporary, new JavaScriptSerializer().Serialize(state), new UTF8Encoding(false));
        if (File.Exists(destination)) File.Replace(temporary, destination, null);
        else File.Move(temporary, destination);
    }

    [STAThread]
    public static void Main(string[] args)
    {
        if (args.Length != 2 || !Directory.Exists(args[0])) return;
        SetProcessDPIAware();
        Application.EnableVisualStyles();
        Application.Run(new Win10CaptureTarget(args[0], args[1]));
    }
}
