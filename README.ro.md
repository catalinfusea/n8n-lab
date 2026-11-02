# n8n standalone (Vagrant + VMware) - instructiuni

Fisiere: `G:\AI\AI pipelines\`
- `Install-n8n-Lab.ps1` - genereaza proiectul (Vagrantfile, docker-compose.yml, .env, Start-n8n-Tunnel.ps1) si porneste VM-ul
- `n8n\` - folderul proiectului (aici rulezi toate comenzile `vagrant`)

Toate comenzile sunt **pe host** (PowerShell pe Windows), daca nu scrie altfel.

## Ce se instaleaza

- VM Ubuntu 24.04 (`bento/ubuntu-24.04`), 2 vCPU / 4 GB RAM, pe VMware NAT (VMnet8). **Nu e legat de laboratorul pfSense.**
- Docker + n8n **2.45.7** (fixat, nu `latest`) + PostgreSQL 16, in `/opt/n8n` in guest.
- n8n asculta doar pe `127.0.0.1:5678` in guest. Din host se ajunge prin tunel SSH.
- Fara Portainer, fara folder partajat `/vagrant`, SSH in guest doar cu cheie.

## Cerinte

- Vagrant + plugin `vagrant-vmware-desktop` + serviciul *Vagrant VMware Utility* pornit (scriptul le verifica)
- VMware Workstation
- Pentru Ollama: Ollama pornit pe host, ascultand pe `127.0.0.1:11434`

## 1. Instalare de la zero

Daca exista un VM vechi: `cd "G:\AI\AI pipelines\n8n"; vagrant destroy -f`

Apoi:

`cd "G:\AI\AI pipelines"; powershell -ExecutionPolicy Bypass -File .\Install-n8n-Lab.ps1`

La intrebarea *Start VM installation now?* raspunzi `Y`.

Ce trebuie sa stii inainte:
- `vagrant up` **reporneste serviciul VMware NAT**. WAN-ul pfSense (daca e pornit) pierde conectivitatea cateva secunde. Cel mai curat: opreste laboratorul inainte.
- Vagrant poate rescrie forward-urile din `C:\ProgramData\VMware\vmnetnat.conf`. Scriptul face backup in `n8n\vmnetnat.conf.bak-<data>` si afiseaza diferentele la final. Calea e din memorie; daca nu exista, scriptul doar avertizeaza.
- `.env` se creeaza **o singura data** si nu se mai rescrie. Daca vrei secrete noi, il stergi inainte: `Remove-Item "G:\AI\AI pipelines\n8n\.env"`
- `vagrant destroy` sterge si volumele din VM: contul n8n, workflow-urile si credentialele dispar. `.env` ramane pe host.

La final, in output trebuie sa apara:
- `n8n is up on 127.0.0.1:5678 (guest).`
- linia din `ss` cu `127.0.0.1:5678` (nu `0.0.0.0`)

## 2. Acces la n8n

`cd "G:\AI\AI pipelines\n8n"; .\Start-n8n-Tunnel.ps1`

- Fereastra ramane fara output - e normal. Ctrl+C inchide tunelul.
- Browser: http://localhost:5678
- Prima deschidere cere crearea contului de owner (email orice format valid, nu se trimite niciun mail; parola in password manager - nu exista "forgot password" fara SMTP).
- Formularele de personalizare si "Unlock" (licenta gratuita Registered Community: Folders, Debug in editor, Custom execution data) sunt optionale. Unlock cere email.
- Scriptul de tunel verifica ca Ollama ruleaza pe host; daca nu, se opreste cu eroare.

## 3. Ollama din n8n

Doar cu tunelul deschis (`Start-n8n-Tunnel.ps1`). Ollama ramane pe loopback pe host, nimic nu se expune pe VMnet8.

1. Creezi un workflow cu nodul **AI Agent** (din editorul de workflow-uri, nu din selectorul de modele cloud).
2. Ii atasezi sub-nodul **Ollama Chat Model**.
3. Credentiala: **Base URL** `http://host.docker.internal:11434` (fara `/v1`, fara API key).
4. Model: numele exact din `ollama list` (cu tot cu tag), rulat pe host.

Selectorul de modele din ecranul "Connect a model" / agent contine doar furnizori cloud; nu pune acolo URL-uri inventate.

Verificare legatura (cu tunelul deschis, intr-un al doilea terminal):

`cd "G:\AI\AI pipelines\n8n"; vagrant ssh -c "sudo docker exec n8n wget -qO- http://host.docker.internal:11434/api/tags"`

Daca intoarce lista de modele, functioneaza. Netestat de mine pe sistemul tau.

## 4. Uz zilnic

| Ce | Comanda (din `G:\AI\AI pipelines\n8n`) |
|---|---|
| Pornire VM | `vagrant up` (reporneste din nou NAT-ul VMware) |
| Oprire VM | `vagrant halt` |
| Stare | `vagrant status` |
| Containere | `vagrant ssh -c "sudo docker ps"` |
| Loguri n8n | `vagrant ssh -c "sudo docker logs --tail 100 n8n"` |
| Reaplicare config | `vagrant provision` |

Cat timp VM-ul e oprit, nu atinge VMnet8 sau pfSense.

## 5. Backup (important)

- **`.env`** (in `n8n\`): contine `N8N_ENCRYPTION_KEY`. Fara el, credentialele salvate in n8n nu mai pot fi decriptate. Copie in password manager / alt disc.
- Workflow-urile: export din UI sau CLI n8n (`n8n export:workflow --backup --output=...` in container).
- `vmnetnat.conf.bak-*`: contine forward-urile NAT de dinainte de `vagrant up`. Nu-l restaura integral (porturi in conflict cu forward-ul SSH al VM-ului n8n).

## 6. Actualizare n8n

Versiunea e fixata in `docker-compose.yml` (`image: docker.n8n.io/n8nio/n8n:2.45.7`). Pentru alta versiune:
1. Backup `.env` + export workflow-uri.
2. Schimbi tag-ul in `docker-compose.yml`, apoi `vagrant provision`.

**n8n 3.x** (beta din 27 oct. 2026, stabil anuntat pentru inceputul lui decembrie) are breaking changes (ex. timeout Code node 5 min -> 1 min) si upgrade-ul e one-way. Citeste mai intai *v3.0 breaking changes* si Migration Report din n8n: https://docs.n8n.io/changelog/v30-breaking-changes

## 7. Depanare

| Simptom | Cauza / actiune |
|---|---|
| `A Vagrant environment or target machine is required` | Esti in alt folder. `cd "G:\AI\AI pipelines\n8n"` |
| `Missing privilege separation directory: /run/sshd` | Bug corectat in versiunea curenta a scriptului. Daca apare, ai un Vagrantfile vechi: regenereaza cu scriptul v2. |
| Tunelul: `Nothing listens on 127.0.0.1:11434` | Porneste Ollama pe host. |
| Tunelul: `Could not read the docker0 IP` | VM-ul nu ruleaza. `vagrant up`. |
| n8n 403 la Ollama | Ollama poate respinge header-ul `Host` necunoscut (din memorie, neverificat). Spune-mi si schimbam numele gazdei. |
| n8n nu se deschide | `vagrant ssh -c "sudo docker compose -f /opt/n8n/docker-compose.yml logs n8n"` |
| `docker compose pull` esueaza pe tag | Verifica tag-ul pe registry; schimba versiunea in compose. Tag-ul `2.45.7` l-am luat din docs-ul n8n, dar nu l-am putut confirma pe registry. |
| Alte VM-uri pierd reteaua la `vagrant up` | Comportament cunoscut: Vagrant reporneste serviciul NAT VMware. Ruleaza `up` cu laboratorul oprit. |
| Forward-uri NAT dispar | Compara `vmnetnat.conf` cu backup-ul `.bak-*`. |

## 8. Ce NU e verificat

- Tunelul SSH invers spre Ollama (accesibilitatea `172.17.0.1` din container) - netestat.
- Calea `C:\ProgramData\VMware\vmnetnat.conf` - din memorie.
- Existenta tag-ului `2.45.7` pe registry.
- Au fost testate doar: sintaxa Vagrantfile / bash / PowerShell si validarea compose-ului.

## 9. Risc ramas

VM-ul e pe VMnet8, aceeasi retea NAT cu WAN-ul pfSense. Workflow-urile n8n pot ajunge in iesire la orice VM care are adaptor pe NAT. Pentru izolare completa, VM-ul se muta pe un segment din spatele pfSense (VMnet4/5) cu reguli explicite.
