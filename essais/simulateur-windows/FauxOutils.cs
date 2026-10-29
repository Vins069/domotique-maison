// FauxOutils.cs : faux wsl.exe et faux usbipd.exe du simulateur Windows d'OpenQIARA Claude V15.
// Un seul programme, compile deux fois sous deux noms (Add-Type -OutputType ConsoleApplication, C# 5 :
// le compilateur de .NET Framework 4 livre avec Windows). Il imite les reponses et les messages d'erreur des vrais
// outils, tient leur etat dans un fichier, et journalise chaque appel (arguments, dossier courant) pour verification.
// Rien n'est installe, rien ne touche au vrai WSL ni aux vrais peripheriques USB.
//
// Variables d'environnement (posees par le simulateur pour chaque scenario) :
//   SIM_DOSSIER   dossier du scenario : appels.log, etat-usb.txt, captures\
//   SIM_NOYAU     reponse de « uname -r » (defaut 6.6.87.2-microsoft-standard-WSL2)
//   SIM_E2FS      ok | ko        installation de e2fsprogs dans la distribution
//   SIM_ATTACH    ok | ko        usbipd attach
//   SIM_BIND      ok | ko        usbipd bind
//   SIM_CARTE     une | aucune | deux    disque(s) apparaissant dans WSL apres l'attachement
//   SIM_OUTIL     code de sortie de preparer-carte-sd.sh / mettre-a-niveau.sh (defaut 0)
//   SIM_SH        ok | ko        sh -c (copie de la cle)
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

public static class FauxOutils
{
    static string Dossier;
    static StreamWriter Sortie;
    static StreamWriter Erreur;

    static string Env(string n, string d)
    {
        string v = Environment.GetEnvironmentVariable(n);
        return string.IsNullOrEmpty(v) ? d : v;
    }

    static void Journal(string ligne)
    {
        for (int essai = 0; essai < 20; essai++)
        {
            try
            {
                File.AppendAllText(Path.Combine(Dossier, "appels.log"), ligne + "\n", new UTF8Encoding(false));
                return;
            }
            catch (IOException) { Thread.Sleep(50); }
        }
    }

    public static int Main(string[] a)
    {
        // sortie en UTF-8 sans BOM, comme les programmes Linux lances par wsl.exe
        Sortie = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false));
        Sortie.AutoFlush = true;
        Erreur = new StreamWriter(Console.OpenStandardError(), new UTF8Encoding(false));
        Erreur.AutoFlush = true;
        Dossier = Env("SIM_DOSSIER", Path.GetTempPath());
        Directory.CreateDirectory(Path.Combine(Dossier, "captures"));
        string nom = Path.GetFileNameWithoutExtension(System.Reflection.Assembly.GetEntryAssembly().Location).ToLowerInvariant();
        Journal(nom + "\t" + Environment.CurrentDirectory + "\t" + string.Join("¦", a));
        try
        {
            return nom == "usbipd" ? Usbipd(a) : Wsl(a);
        }
        catch (Exception e)
        {
            Erreur.WriteLine("faux " + nom + " : " + e.Message);
            Journal("EXCEPTION\t" + e.ToString().Replace("\n", " "));
            return 99;
        }
    }

    // ------------------------------------------------------------------ chemins Windows <-> WSL
    public static string VersWsl(string p)
    {
        if (p.Length >= 2 && p[1] == ':' && char.IsLetter(p[0]))
        {
            string reste = p.Substring(2).Replace('\\', '/');
            if (!reste.StartsWith("/")) reste = "/" + reste;
            return "/mnt/" + char.ToLowerInvariant(p[0]) + reste.TrimEnd('/');
        }
        return p;
    }

    public static string VersWindows(string p)
    {
        if (p.StartsWith("/mnt/") && p.Length >= 6 && char.IsLetter(p[5]) && (p.Length == 6 || p[6] == '/'))
        {
            string reste = p.Length > 6 ? p.Substring(6).Replace('/', '\\') : "\\";
            return char.ToUpperInvariant(p[5]) + ":" + reste;
        }
        return null;   // chemin interne a la distribution
    }

    // ------------------------------------------------------------------ wsl.exe
    static int Wsl(string[] a)
    {
        string cd = null;
        List<string> cmd = new List<string>();
        int i = 0;
        while (i < a.Length)
        {
            string x = a[i];
            if (x == "-u" || x == "--user" || x == "-d" || x == "--distribution") { i += 2; continue; }
            if (x == "--cd") { cd = i + 1 < a.Length ? a[i + 1] : null; i += 2; continue; }
            if (x == "-e" || x == "--exec") { for (int j = i + 1; j < a.Length; j++) cmd.Add(a[j]); break; }
            if (x == "-l" || x == "--list" || x == "--version" || x == "--status" || x == "--install" || x == "--update" || x == "--shutdown")
            {
                Erreur.WriteLine("faux wsl.exe : option " + x + " non simulee (le script ne devrait pas l'appeler)");
                Journal("ALERTE\toption " + x);
                return 1;
            }
            // commande sans -e : passee par le shell de la distribution (le simulateur le signale)
            for (int j = i; j < a.Length; j++) cmd.Add(a[j]);
            Journal("ALERTE\tcommande sans -e (interpretee par le shell de la distribution) : " + string.Join(" ", cmd.ToArray()));
            break;
        }
        if (cmd.Count == 0) { Erreur.WriteLine("faux wsl.exe : session interactive non simulee"); return 1; }
        string c0 = cmd[0];

        if (c0 == "uname") { Sortie.WriteLine(Env("SIM_NOYAU", "6.6.87.2-microsoft-standard-WSL2")); return 0; }
        if (c0 == "wslpath")
        {
            string p = cmd[cmd.Count - 1];
            Sortie.WriteLine(VersWsl(p));
            return 0;
        }
        if (c0 == "lsblk")
        {
            Sortie.WriteLine("/dev/sda");
            Sortie.WriteLine("/dev/sdb");
            Sortie.WriteLine("/dev/sdc");
            if (EtatUsb("2-3") == "Attached")
            {
                string carte = Env("SIM_CARTE", "une");
                if (carte == "une" || carte == "deux") Sortie.WriteLine("/dev/sdd");
                if (carte == "deux") Sortie.WriteLine("/dev/sde");
            }
            return 0;
        }
        if (c0 == "modprobe" || c0 == "sync" || c0 == "true") return 0;
        if (c0 == "sleep")
        {
            int s; int.TryParse(cmd.Count > 1 ? cmd[1] : "1", out s);
            Thread.Sleep(Math.Min(s, 3600) * 1000);
            return 0;
        }
        if (c0 == "rm") return 0;
        if (c0 == "mkdir" || c0 == "chmod") return Env("SIM_SH", "ok") == "ok" ? 0 : 1;
        if (c0 == "cp")
        {
            if (Env("SIM_SH", "ok") != "ok") { Erreur.WriteLine("cp: cannot create regular file: Permission denied"); return 1; }
            string src = cmd.Count > 2 ? cmd[cmd.Count - 2] : "";
            string w = VersWindows(src);
            if (w != null && !File.Exists(w)) { Erreur.WriteLine("cp: cannot stat '" + src + "': No such file or directory"); return 1; }
            return 0;
        }
        if ((c0 == "bash" || c0 == "sh") && cmd.Count >= 3 && cmd[1] == "-c")
        {
            string s = cmd[2];
            if (s.Contains("command -v debugfs")) return Env("SIM_E2FS", "ok") == "ok" ? 0 : 100;
            return ShellC(s);
        }
        if (c0 == "bash" && cmd.Count >= 2 && (cmd[1] == "./preparer-carte-sd.sh" || cmd[1] == "./mettre-a-niveau.sh"))
            return Outil(cd, cmd);
        Erreur.WriteLine("faux wsl.exe : commande non simulee : " + string.Join(" ", cmd.ToArray()));
        Journal("ALERTE\tcommande non simulee : " + string.Join(" ", cmd.ToArray()));
        return 127;
    }

    // sh -c : imite le decoupage par le shell (apostrophes) pour reperer les chemins mal proteges
    static int ShellC(string s)
    {
        int n = 0; foreach (char ch in s) if (ch == '\'') n++;
        if (n % 2 == 1) { Erreur.WriteLine("sh: 1: Syntax error: Unterminated quoted string"); Journal("SH\terreur de syntaxe (apostrophe non appariee)"); return 2; }
        // chaque segment entre apostrophes qui ressemble a un chemin /mnt/x/ doit exister cote Windows
        string[] seg = s.Split('\'');
        for (int k = 1; k < seg.Length; k += 2)
        {
            string w = VersWindows(seg[k]);
            if (w != null && !File.Exists(w) && !Directory.Exists(w))
            {
                Erreur.WriteLine("cp: cannot stat '" + seg[k] + "': No such file or directory");
                Journal("SH\tchemin introuvable : " + seg[k]);
                return 1;
            }
        }
        return Env("SIM_SH", "ok") == "ok" ? 0 : 1;
    }

    // preparer-carte-sd.sh / mettre-a-niveau.sh : controle de ce que le script Windows transmet, capture, puis reponse
    static int Outil(string cd, List<string> cmd)
    {
        string outil = cmd[1].Substring(2);
        string cdWin = cd == null ? null : VersWindows(cd);
        bool cdOk = cdWin != null && File.Exists(Path.Combine(cdWin, outil));
        Journal("OUTIL\t" + outil + "\tcd=" + cd + "\tcd_ok=" + (cdOk ? "1" : "0") + "\targs=" + string.Join("¦", cmd.GetRange(2, cmd.Count - 2).ToArray()));
        for (int k = 2; k < cmd.Count - 1; k++)
        {
            if (cmd[k] != "--configuration") continue;
            string conf = cmd[k + 1];
            string confWin = VersWindows(conf);
            bool confOk = confWin != null && File.Exists(confWin);
            Journal("CONF\t" + conf + "\texiste=" + (confOk ? "1" : "0"));
            if (!confOk) { Erreur.WriteLine("ERREUR : fichier de configuration introuvable : " + conf); return 1; }
            File.Copy(confWin, Path.Combine(Path.Combine(Dossier, "captures"), outil + "-configuration.txt"), true);
            foreach (string l in File.ReadAllLines(confWin, Encoding.UTF8))
            {
                string t = l.Trim().TrimStart('﻿');
                if (!t.StartsWith("CLE_SSH_PUBLIQUE=")) continue;
                string cle = t.Substring("CLE_SSH_PUBLIQUE=".Length);
                string cleWin = VersWindows(cle);
                Journal("CLE\t" + cle + "\texiste=" + (cleWin == null ? "interne" : (File.Exists(cleWin) ? "1" : "0")));
            }
        }
        File.WriteAllText(Path.Combine(Path.Combine(Dossier, "captures"), outil + "-commande.txt"),
            (cd ?? "") + "\n" + string.Join("\n", cmd.GetRange(1, cmd.Count - 1).ToArray()) + "\n", new UTF8Encoding(false));
        if (!cdOk) { Erreur.WriteLine("bash: " + cmd[1] + ": No such file or directory"); return 127; }
        int code; int.TryParse(Env("SIM_OUTIL", "0"), out code);
        Sortie.WriteLine("=== (simulation) " + outil + " " + string.Join(" ", cmd.GetRange(2, cmd.Count - 2).ToArray()) + " ===");
        Sortie.WriteLine(code == 0 ? "=== (simulation) termine normalement ===" : "ERREUR : (simulation) echec de " + outil);
        return code;
    }

    // ------------------------------------------------------------------ usbipd.exe
    static readonly string[][] Peripheriques = new string[][] {
        new string[] { "1-4", "046d:c52b", "Clavier USB, Périphérique d'entrée USB" },
        new string[] { "2-3", "0bda:0109", "Périphérique de stockage de masse USB" },
    };

    static string FichierEtat() { return Path.Combine(Dossier, "etat-usb.txt"); }

    static Dictionary<string, string> LireEtat()
    {
        Dictionary<string, string> d = new Dictionary<string, string>();
        foreach (string[] p in Peripheriques) d[p[0]] = "Not shared";
        if (File.Exists(FichierEtat()))
            foreach (string l in File.ReadAllLines(FichierEtat()))
            {
                int k = l.IndexOf('=');
                if (k > 0) d[l.Substring(0, k)] = l.Substring(k + 1);
            }
        return d;
    }

    static void EcrireEtat(Dictionary<string, string> d)
    {
        List<string> l = new List<string>();
        foreach (KeyValuePair<string, string> kv in d) l.Add(kv.Key + "=" + kv.Value);
        File.WriteAllLines(FichierEtat(), l.ToArray());
    }

    static string EtatUsb(string id) { string v; return LireEtat().TryGetValue(id, out v) ? v : ""; }

    static string Option(string[] a, string longue, string courte)
    {
        for (int i = 0; i < a.Length - 1; i++) if (a[i] == longue || a[i] == courte) return a[i + 1];
        foreach (string x in a) if (x.StartsWith(longue + "=")) return x.Substring(longue.Length + 1);
        return null;
    }

    static bool A(string[] a, string longue, string courte) { foreach (string x in a) if (x == longue || x == courte) return true; return false; }

    static int Usbipd(string[] a)
    {
        if (a.Length == 0) { Erreur.WriteLine("usbipd: error: Required command was not provided."); return 1; }
        Dictionary<string, string> etat = LireEtat();
        string verbe = a[0];
        if (verbe == "list")
        {
            Sortie.WriteLine("Connected:");
            Sortie.WriteLine("BUSID  VID:PID    DEVICE                                                        STATE");
            foreach (string[] p in Peripheriques)
                Sortie.WriteLine(p[0].PadRight(7) + p[1].PadRight(11) + p[2].PadRight(62) + etat[p[0]]);
            Sortie.WriteLine("");
            Sortie.WriteLine("Persisted:");
            Sortie.WriteLine("GUID                                  DEVICE");
            Sortie.WriteLine("");
            return 0;
        }
        string id = Option(a, "--busid", "-b");
        if (id == null) { Erreur.WriteLine("usbipd: error: Option '--busid' is required."); return 1; }
        if (!etat.ContainsKey(id)) { Erreur.WriteLine("usbipd: error: There is no device with busid '" + id + "'."); return 1; }
        if (verbe == "bind")
        {
            if (Env("SIM_BIND", "ok") != "ok") { Erreur.WriteLine("usbipd: error: Access denied."); return 1; }
            if (etat[id] == "Not shared") etat[id] = "Shared";
            EcrireEtat(etat); return 0;
        }
        if (verbe == "attach")
        {
            if (!A(a, "--wsl", "-w")) { Erreur.WriteLine("Option '--wsl' is required."); return 1; }
            if (etat[id] == "Not shared") { Erreur.WriteLine("usbipd: error: Device is not shared; run 'usbipd bind -b " + id + "' as administrator first."); return 1; }
            if (etat[id] == "Attached") { Erreur.WriteLine("usbipd: error: Device is already attached to a client."); return 1; }
            if (Env("SIM_ATTACH", "ok") != "ok") { Erreur.WriteLine("usbipd: error: Attaching failed; the device may be in use by another program."); return 1; }
            Sortie.WriteLine("usbipd: info: Using WSL distribution 'Ubuntu' to attach; the device will be available in all WSL 2 distributions.");
            etat[id] = "Attached"; EcrireEtat(etat); return 0;
        }
        if (verbe == "detach")
        {
            if (etat[id] != "Attached") { Erreur.WriteLine("usbipd: error: Device is not attached."); return 1; }
            etat[id] = "Shared"; EcrireEtat(etat); return 0;
        }
        if (verbe == "unbind")
        {
            if (etat[id] == "Attached") { Erreur.WriteLine("usbipd: warning: Device is attached; it will be detached."); }
            etat[id] = "Not shared"; EcrireEtat(etat); return 0;
        }
        Erreur.WriteLine("usbipd: error: Unrecognized command '" + verbe + "'.");
        return 1;
    }
}
