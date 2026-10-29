# -*- coding: utf-8 -*-
"""Mesure d'un flux RTSP H.264 ou H.265 (Claude, 25/10/2026 ; H.265 le 27/10/2026, axe D) - sans dependance.

Usage : python rtsp_mesure.py rtsp://hote:port/chemin DUREE_S PREFIXE_SORTIE

Se connecte en RTSP/TCP entrelace (comme go2rtc et Home Assistant), lit la piste video et enregistre :
  - PREFIXE.paquets.csv : arrivee (s), seq, horodatage RTP, marqueur, taille, type NAL ;
  - PREFIXE.images.csv  : une ligne par image (horodatage RTP, 1er et dernier paquet, octets, cle, paquets perdus) ;
  - PREFIXE.h264 ou .h265 : le flux Annex-B (jeux de parametres du SDP en tete), pour decodage et images ;
  - PREFIXE.resume.json : SDP, codec, debit, images/s, ecarts, pertes.
Le codec est lu dans le SDP (a=rtpmap H264 ou H265). En H.264 (RFC 6184) : type NAL sur 5 bits, FU-A 28, STAP-A 24,
image cle = IDR (5) ou SPS/PPS (7, 8). En H.265 (RFC 7798) : en-tete de 2 octets, type sur 6 bits, FU 49, AP 48,
image cle = IRAP (16 a 23) ou VPS/SPS/PPS (32 a 34). Ne fait que lire.
"""
import base64
import json
import re
import socket
import sys
import time

URL, DUREE, PREF = sys.argv[1], float(sys.argv[2]), sys.argv[3]
m = re.match(r"rtsp://([^/:]+)(?::(\d+))?(/.*)?", URL)
HOTE, PORT = m.group(1), int(m.group(2) or 554)
s = socket.create_connection((HOTE, PORT), timeout=15)
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
    s.sendall(f"{methode} {url} RTSP/1.0\r\nCSeq: {cseq}\r\nUser-Agent: claude-mesure\r\n{sess}{extra}\r\n".encode())
    return lire_entete()


t, corps = requete("DESCRIBE", URL, "Accept: application/sdp\r\n")
sdp = corps.decode("utf-8", "replace")
base_url = URL
mb = re.search(r"Content-Base:\s*(\S+)", t, re.I)
if mb:
    base_url = mb.group(1)
# piste video et codec (H264 ou H265 dans a=rtpmap)
video = sdp.split("m=video", 1)[1].split("\nm=", 1)[0]
ctrl = re.search(r"a=control:(\S+)", video).group(1)
url_piste = ctrl if ctrl.startswith("rtsp://") else base_url.rstrip("/") + "/" + ctrl
mcodec = re.search(r"a=rtpmap:\d+\s+(H26[45])/90000", video, re.I)
CODEC = mcodec.group(1).upper() if mcodec else "H264"
H265 = CODEC == "H265"
# jeux de parametres du SDP, dans l'ordre de decodage : H.264 sprop-parameter-sets (SPS,PPS) ; H.265 sprop-vps, sprop-sps, sprop-pps
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

f264 = open(PREF + (".h265" if H265 else ".h264"), "wb")
for p in sprops:
    f264.write(b"\x00\x00\x00\x01" + base64.b64decode(p + "=" * (-len(p) % 4)))


def type_nal(octets):
    """Type NAL d'une unite sans code de debut : 5 bits en H.264, 6 bits (second bit du 1er octet) en H.265."""
    return ((octets[0] >> 1) & 0x3F) if H265 else (octets[0] & 0x1F)


def est_cle(typ):
    """Image cle ou jeu de parametres : IDR/SPS/PPS en H.264, IRAP (16 a 23) ou VPS/SPS/PPS (32 a 34) en H.265."""
    if H265:
        return 16 <= typ <= 23 or 32 <= typ <= 34
    return typ in (5, 7, 8)


fu = None                                 # fragment en cours d'assemblage (None : aucun, ou premier paquet perdu)
FU, AP = (49, 48) if H265 else (28, 24)   # fragmentation et agregation : RFC 7798 (H.265), RFC 6184 (H.264)
TETE = 2 if H265 else 1                   # taille de l'en-tete NAL
fp = open(PREF + ".paquets.csv", "w")
fp.write("arrivee;seq;ts;marqueur;taille;nal\n")
fi = open(PREF + ".images.csv", "w")
fi.write("ts;premier;dernier;octets;paquets;cle;perdus\n")

t0 = time.perf_counter()
dernier_ka = t0
seq_prec = None
perdus_total = 0
img = None  # [ts, premier, dernier, octets, paquets, cle, perdus]
nb_paquets = 0
octets = 0


def fin_image():
    if img:
        fi.write(";".join(str(x) for x in [img[0], f"{img[1]:.4f}", f"{img[2]:.4f}", img[3], img[4], img[5], img[6]]) + "\n")


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
        lire_entete()  # reponse a OPTIONS
        continue
    canal, longueur = lire(1)[0], int.from_bytes(lire(2), "big")
    p = lire(longueur)
    arrivee = time.perf_counter() - t0
    if canal != 0 or len(p) < 12:
        continue
    cc = p[0] & 0x0F
    marqueur = (p[1] >> 7) & 1
    seq = int.from_bytes(p[2:4], "big")
    ts = int.from_bytes(p[4:8], "big")
    charge = p[12 + 4 * cc:]
    if p[0] & 0x10:  # extension
        lx = int.from_bytes(charge[2:4], "big")
        charge = charge[4 + 4 * lx:]
    perdus = 0
    if seq_prec is not None:
        ecart = (seq - seq_prec) & 0xFFFF
        if ecart != 1:
            perdus = (ecart - 1) if ecart < 30000 else 0
            perdus_total += perdus
    seq_prec = seq
    nal = type_nal(charge)
    if nal == FU:  # unite de fragmentation : FU-A (H.264) ou FU (H.265, en-tete de 2 octets puis en-tete FU)
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
            f264.write(b"\x00\x00\x00\x01" + bytes(fu))
        if tete & 0x40:
            fu = None  # fin de fragment ; un fragment orphelin (premier paquet perdu) n'est jamais assemble
        nal_vrai = typ
    elif nal == AP:  # agregation : STAP-A (H.264) ou AP (H.265)
        i = TETE
        while i + 2 <= len(charge):
            n = int.from_bytes(charge[i:i + 2], "big")
            f264.write(b"\x00\x00\x00\x01" + charge[i + 2:i + 2 + n])
            i += 2 + n
        nal_vrai = AP
    else:
        f264.write(b"\x00\x00\x00\x01" + charge)
        nal_vrai = nal
    nb_paquets += 1
    octets += len(p)
    fp.write(f"{arrivee:.5f};{seq};{ts};{marqueur};{len(p)};{nal_vrai}\n")
    if img is None or img[0] != ts:
        fin_image()
        img = [ts, arrivee, arrivee, 0, 0, 0, 0]
    img[2] = arrivee
    img[3] += len(p)
    img[4] += 1
    img[6] += perdus
    if est_cle(nal_vrai):
        img[5] = 1

fin_image()
duree = time.perf_counter() - t0
try:
    requete("TEARDOWN", base_url)
except Exception:
    pass
s.close()
for f in (f264, fp, fi):
    f.close()
json.dump(
    {
        "url": URL,
        "codec": CODEC,
        "duree_s": round(duree, 2),
        "paquets": nb_paquets,
        "octets": octets,
        "debit_mbits": round(octets * 8 / duree / 1e6, 3),
        "paquets_perdus": perdus_total,
        "sdp": sdp,
    },
    open(PREF + ".resume.json", "w"),
    indent=1,
)
print(f"fini : {nb_paquets} paquets, {octets * 8 / duree / 1e6:.2f} Mbit/s, {perdus_total} perdus")
