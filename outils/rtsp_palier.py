# -*- coding: utf-8 -*-
"""Mesure longue d'un flux RTSP H.264 ou H.265 pour un palier de debit (Claude, 28/10/2026) - sans dependance.

Usage : python rtsp_palier.py rtsp://hote:port/chemin DUREE_S PREFIXE_SORTIE [FLUX_S]

Derive de rtsp_mesure.py (meme lecture RTSP/TCP entrelacee, memes regles RFC 6184 / RFC 7798), mais prevu pour des
lectures de plusieurs minutes : le flux brut n'est pas conserve (sauf les FLUX_S premieres secondes si demande, pour
regarder une image), et les resultats sont resumes par fenetres de 10 s. Ecrit :
  - PREFIXE.fenetres.csv : par fenetre de 10 s : octets, debit (Mbit/s), paquets, paquets perdus, images, images cles,
    ecart maximal entre deux images (s) ;
  - PREFIXE.images.csv   : une ligne par image (horodatage RTP, arrivee, octets, paquets, cle, perdus) ;
  - PREFIXE.h264/.h265   : les FLUX_S premieres secondes (jeux de parametres du SDP en tete) si FLUX_S > 0 ;
  - PREFIXE.resume.json  : totaux (debit, images/s, pertes, intervalle des images cles, plus long gel, coupure).
Un paquet perdu = un saut dans les numeros de sequence RTP (OpenQiara jette des paquets quand son client ne suit pas :
« client trop lent », file d'ecriture pleine, en pratique quand le Wi-Fi de la camera ne suit pas). Ne fait que lire.
"""
import base64
import json
import re
import socket
import sys
import time

URL, DUREE, PREF = sys.argv[1], float(sys.argv[2]), sys.argv[3]
FLUX_S = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0
FENETRE = 10.0
m = re.match(r"rtsp://([^/:]+)(?::(\d+))?(/.*)?", URL)
HOTE, PORT = m.group(1), int(m.group(2) or 554)
s = socket.create_connection((HOTE, PORT), timeout=20)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 21)
tampon = b""
cseq = 0
session = None


def lire(n):
    global tampon
    while len(tampon) < n:
        d = s.recv(1 << 16)
        if not d:
            raise EOFError("connexion fermee")
        tampon += d
    r, tampon = tampon[:n], tampon[n:]
    return r


def lire_entete():
    global tampon
    while b"\r\n\r\n" not in tampon:
        d = s.recv(1 << 16)
        if not d:
            raise EOFError("connexion fermee")
        tampon += d
    tete, _, tampon = tampon.partition(b"\r\n\r\n")
    texte = tete.decode("utf-8", "replace")
    mm = re.search(r"Content-Length:\s*(\d+)", texte, re.I)
    corps = lire(int(mm.group(1))) if mm else b""
    return texte, corps


def requete(methode, url, extra=""):
    global cseq
    cseq += 1
    sess = f"Session: {session}\r\n" if session else ""
    s.sendall(f"{methode} {url} RTSP/1.0\r\nCSeq: {cseq}\r\nUser-Agent: claude-palier\r\n{sess}{extra}\r\n".encode())
    return lire_entete()


t, corps = requete("DESCRIBE", URL, "Accept: application/sdp\r\n")
sdp = corps.decode("utf-8", "replace")
base_url = URL
mb = re.search(r"Content-Base:\s*(\S+)", t, re.I)
if mb:
    base_url = mb.group(1)
video = sdp.split("m=video", 1)[1].split("\nm=", 1)[0]
ctrl = re.search(r"a=control:(\S+)", video).group(1)
url_piste = ctrl if ctrl.startswith("rtsp://") else base_url.rstrip("/") + "/" + ctrl
mcodec = re.search(r"a=rtpmap:\d+\s+(H26[45])/90000", video, re.I)
CODEC = mcodec.group(1).upper() if mcodec else "H264"
H265 = CODEC == "H265"
sprops = []
if H265:
    for nom in ("sprop-vps", "sprop-sps", "sprop-pps"):
        m1 = re.search(nom + r"=([^;\s]+)", video)
        if m1:
            sprops.append(m1.group(1))
else:
    sprop = re.search(r"sprop-parameter-sets=([^;\s]+)", video)
    if sprop:
        sprops = sprop.group(1).split(",")
t, _ = requete("SETUP", url_piste, "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n")
session = re.search(r"Session:\s*([^;\r\n]+)", t, re.I).group(1).strip()
t, _ = requete("PLAY", base_url, "Range: npt=0.000-\r\n")

fflux = None
if FLUX_S > 0:
    fflux = open(PREF + (".h265" if H265 else ".h264"), "wb")
    for p in sprops:
        fflux.write(b"\x00\x00\x00\x01" + base64.b64decode(p + "=" * (-len(p) % 4)))


def type_nal(octets):
    return ((octets[0] >> 1) & 0x3F) if H265 else (octets[0] & 0x1F)


def est_cle(typ):
    if H265:
        return 16 <= typ <= 23 or 32 <= typ <= 34
    return typ in (5, 7, 8)


def ecrire_flux(nal_bytes, arrivee):
    if fflux is not None and arrivee <= FLUX_S:
        fflux.write(b"\x00\x00\x00\x01" + nal_bytes)


fu = None
FU, AP = (49, 48) if H265 else (28, 24)
TETE = 2 if H265 else 1
fi = open(PREF + ".images.csv", "w")
fi.write("ts;arrivee;octets;paquets;cle;perdus\n")
ff = open(PREF + ".fenetres.csv", "w")
ff.write("debut_s;octets;debit_mbits;paquets;perdus;images;cles;ecart_max_images_s\n")

t0 = time.perf_counter()
dernier_ka = t0
seq_prec = None
perdus_total = 0
img = None  # [ts, arrivee, octets, paquets, cle, perdus]
nb_paquets = 0
octets = 0
images = 0
cles = 0
arrivee_img_prec = None
gel_max = 0.0            # plus long ecart entre deux images successives (s)
gel_max_a = 0.0          # instant de ce gel
ts_cle_prec = None
intervalles_cles = []    # ecarts entre images cles (s, horloge RTP 90 kHz)
tailles_cles = []
tailles_p = []
coupure = ""
# fenetre courante
fw = [0.0, 0, 0, 0, 0, 0, 0.0]  # debut, octets, paquets, perdus, images, cles, ecart max


def fin_fenetre(d=FENETRE):
    d = max(d, 0.5)
    ff.write(f"{fw[0]:.0f};{fw[1]};{fw[1] * 8 / d / 1e6:.3f};{fw[2]};{fw[3]};{fw[4]};{fw[5]};{fw[6]:.3f}\n")


def fin_image():
    global images, cles, arrivee_img_prec, gel_max, gel_max_a, ts_cle_prec
    if not img:
        return
    images += 1
    fw[4] += 1
    fi.write(f"{img[0]};{img[1]:.4f};{img[2]};{img[3]};{img[4]};{img[5]}\n")
    if arrivee_img_prec is not None:
        e = img[1] - arrivee_img_prec
        if e > fw[6]:
            fw[6] = e
        if e > gel_max:
            gel_max, gel_max_a = e, img[1]
    arrivee_img_prec = img[1]
    if img[4]:
        cles += 1
        fw[5] += 1
        tailles_cles.append(img[2])
        if ts_cle_prec is not None:
            intervalles_cles.append(((img[0] - ts_cle_prec) & 0xFFFFFFFF) / 90000.0)
        ts_cle_prec = img[0]
    else:
        tailles_p.append(img[2])


try:
    while True:
        maintenant = time.perf_counter()
        if maintenant - t0 > DUREE:
            break
        if maintenant - dernier_ka > 5:
            cseq += 1
            s.sendall(f"OPTIONS {base_url} RTSP/1.0\r\nCSeq: {cseq}\r\nSession: {session}\r\n\r\n".encode())
            dernier_ka = maintenant
        c = lire(1)
        if c != b"$":
            tampon = c + tampon
            lire_entete()
            continue
        canal, longueur = lire(1)[0], int.from_bytes(lire(2), "big")
        p = lire(longueur)
        arrivee = time.perf_counter() - t0
        if canal != 0 or len(p) < 12:
            continue
        while arrivee >= fw[0] + FENETRE:
            fin_fenetre()
            fw[0] += FENETRE
            fw[1] = fw[2] = fw[3] = fw[4] = fw[5] = 0
            fw[6] = 0.0
        cc = p[0] & 0x0F
        seq = int.from_bytes(p[2:4], "big")
        ts = int.from_bytes(p[4:8], "big")
        charge = p[12 + 4 * cc:]
        if p[0] & 0x10:
            lx = int.from_bytes(charge[2:4], "big")
            charge = charge[4 + 4 * lx:]
        perdus = 0
        if seq_prec is not None:
            ecart = (seq - seq_prec) & 0xFFFF
            if ecart != 1:
                perdus = (ecart - 1) if ecart < 30000 else 0
                perdus_total += perdus
                fw[3] += perdus
        seq_prec = seq
        nal = type_nal(charge)
        if nal == FU:
            tete = charge[TETE]
            typ = tete & 0x3F if H265 else tete & 0x1F
            if tete & 0x80:
                if H265:
                    fu = bytearray([(charge[0] & 0x81) | (typ << 1), charge[1]]) + charge[3:]
                else:
                    fu = bytearray([(charge[0] & 0xE0) | typ]) + charge[2:]
            elif fu is not None:
                fu += charge[TETE + 1:]
            if tete & 0x40 and fu is not None:
                ecrire_flux(bytes(fu), arrivee)
            if tete & 0x40:
                fu = None
            nal_vrai = typ
        elif nal == AP:
            i = TETE
            while i + 2 <= len(charge):
                n = int.from_bytes(charge[i:i + 2], "big")
                ecrire_flux(charge[i + 2:i + 2 + n], arrivee)
                i += 2 + n
            nal_vrai = AP
        else:
            ecrire_flux(charge, arrivee)
            nal_vrai = nal
        nb_paquets += 1
        octets += len(p)
        fw[1] += len(p)
        fw[2] += 1
        if img is None or img[0] != ts:
            fin_image()
            img = [ts, arrivee, 0, 0, 0, 0]
        img[2] += len(p)
        img[3] += 1
        img[5] += perdus
        if est_cle(nal_vrai):
            img[4] = 1
except (socket.timeout, EOFError, ConnectionError, OSError) as e:
    coupure = f"{type(e).__name__}: {e} a {time.perf_counter() - t0:.1f} s"

fin_image()
duree = time.perf_counter() - t0
fin_fenetre(duree - fw[0])
try:
    s.settimeout(5)
    requete("TEARDOWN", base_url)
except Exception:
    pass
s.close()
for f in (fflux, fi, ff):
    if f is not None:
        f.close()


def moy(v):
    return round(sum(v) / len(v), 3) if v else None


resume = {
    "url": URL,
    "codec": CODEC,
    "duree_s": round(duree, 2),
    "paquets": nb_paquets,
    "octets": octets,
    "debit_mbits": round(octets * 8 / duree / 1e6, 3) if duree > 0 else None,
    "paquets_perdus": perdus_total,
    "images": images,
    "images_par_s": round(images / duree, 2) if duree > 0 else None,
    "images_cles": cles,
    "intervalle_cle_s": moy(intervalles_cles),
    "intervalle_cle_max_s": round(max(intervalles_cles), 3) if intervalles_cles else None,
    "taille_cle_moy_o": moy(tailles_cles),
    "taille_p_moy_o": moy(tailles_p),
    "gel_max_s": round(gel_max, 3),
    "gel_max_a_s": round(gel_max_a, 1),
    "coupure": coupure,
    "sdp": sdp,
}
json.dump(resume, open(PREF + ".resume.json", "w"), indent=1)
print(
    f"fini : {duree:.0f} s, {nb_paquets} paquets, {resume['debit_mbits']} Mbit/s, {perdus_total} perdus, "
    f"{images} images ({resume['images_par_s']} i/s), {cles} cles (intervalle {resume['intervalle_cle_s']} s), "
    f"gel max {gel_max:.2f} s" + (f", COUPURE {coupure}" if coupure else "")
)
