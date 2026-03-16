# CoreMP135 — IoT Gateway Provisioning

Scripts de provisioning automatique pour les boxes **M5Stack CoreMP135** (Debian ARM7).

Un seul script transforme une box fraîchement reçue du constructeur en gateway IoT opérationnelle avec :

- **ThingsBoard IoT Gateway** (Docker, tous les connecteurs activés)
- **Tailscale** — reverse VPN mesh pour accès distant sécurisé (SSH, monitoring)

---

## Prérequis

| Élément | Détail |
|---|---|
| Hardware | M5Stack CoreMP135, Debian Bookworm/Bullseye ARM7 préinstallé |
| Réseau | Connexion internet sur eth0 au premier boot |
| ThingsBoard | Instance TB accessible, credentials de provisioning disponibles |
| Tailscale | Compte Tailscale, clé d'auth réutilisable générée |

---

## Usage rapide — one-liner

```bash
curl -sSL https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/main/setup.sh \
  | sudo bash -s -- \
      --tb-host=enermon.energroup.ch \
      --tb-provision-key=voa4zhqanziqiqu291fm \
      --tb-provision-secret=z2gmw8tvsfu1outyyyaw \
      --tailscale-key=tskey-auth-XXXXXXXXXXXXX
```

> Le `TB_GW_PROVISIONING_DEVICE_NAME` est automatiquement défini sur l'adresse MAC de `eth0`.

---

## Usage avec fichier .env (recommandé pour déploiements multiples)

```bash
# 1. Télécharger le script et le template
wget https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/main/setup.sh
wget https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/main/.env.example

# 2. Remplir la configuration
cp .env.example .env
nano .env

# 3. Lancer
chmod +x setup.sh
sudo ./setup.sh --env-file=.env
```

---

## Ce que fait le script

```
1. Vérifications préliminaires (root, réseau)
2. Détection MAC address eth0  →  utilisée comme nom de device TB
3. Installation des paquets système
4. Installation Docker + Docker Compose plugin
5. Pull de l'image thingsboard/tb-gateway:latest
6. Génération docker-compose.yml (tous les connecteurs ouverts)
7. Génération .env runtime (permissions 600)
8. Démarrage du container TB Gateway
9. Création service systemd tb-gateway (auto-restart au reboot)
10. Installation Tailscale + connexion au réseau avec hostname coremp135-<MAC>
```

---

## Ports exposés (tous les connecteurs)

| Port | Protocole | Connecteur |
|---|---|---|
| `5000` | TCP | REST |
| `1052` | TCP | BACnet |
| `5026` | TCP | Modbus TCP (Slave) |
| `502` | TCP | Modbus TCP (Master standard) |
| `47808` | UDP | BACnet/IP |
| `50000` | TCP/UDP | Socket connector |
| `4840` | TCP | OPC-UA |

---

## Accès distant via Tailscale

Chaque box rejoint automatiquement ton réseau Tailscale avec le hostname `coremp135-<MAC>`.

```bash
# Depuis n'importe quelle machine sur le même réseau Tailscale :
ssh root@coremp135-d6-03-3f-1e-0b-9f

# Voir toutes les boxes connectées :
tailscale status
```

Pour activer SSH Tailscale sur les boxes, la clé auth doit avoir le flag `--ssh` (inclus dans le script).

> **Recommandation clé Tailscale** : Créer une clé "Reusable + Pre-approved" dans [Tailscale Admin](https://login.tailscale.com/admin/settings/keys) pour que chaque nouvelle box rejoigne le réseau sans validation manuelle.

---

## Commandes utiles sur la box

```bash
# Logs TB Gateway en temps réel
docker compose -f /opt/tb-gateway/docker-compose.yml logs -f

# État des containers
docker compose -f /opt/tb-gateway/docker-compose.yml ps

# Redémarrer le gateway
systemctl restart tb-gateway

# État Tailscale
tailscale status
tailscale ip -4

# Mettre à jour l'image TB Gateway
docker compose -f /opt/tb-gateway/docker-compose.yml pull
systemctl restart tb-gateway
```

---

## Structure du repo

```
.
├── setup.sh          # Script principal de provisioning
├── .env.example      # Template de configuration (à copier en .env)
└── README.md
```

> `.env` est dans `.gitignore` — ne jamais commiter les secrets.

---

## Sécurité

- Le fichier `.env` runtime (dans `/opt/tb-gateway/`) a les permissions `600` (root only)
- Les secrets ne transitent pas dans les logs Docker (passés via `env_file`)
- Tailscale chiffre tout le trafic de management (WireGuard sous le capot)
- Le SSH Tailscale bypass le port 22 exposé publiquement — pas besoin d'ouvrir de port firewall

---

## Mise à jour d'une box existante

```bash
curl -sSL https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/main/setup.sh \
  | sudo bash -s -- --env-file=/opt/tb-gateway/.env
```

Le script est idempotent : il ne réinstalle que ce qui manque, et fait un `docker pull` pour récupérer la dernière image TB Gateway.
