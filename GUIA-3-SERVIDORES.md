# Arquitectura v3.0 en 3 servidores · distribución de herramientas y laboratorio en Docker

## 1. Resumen

La arquitectura v3.0 reparte la plataforma en tres servidores aislados. El informe técnico pone las herramientas concretas en cada uno:

- **S1 Aplicaciones:** todo lo que tocan los usuarios. Proxy con WAF, Keycloak, backend del portal, portal React, Superset y la API de Cube.
- **S2 Datos:** todo lo que guarda o mueve datos. Kafka, Kafka Connect con Debezium y el sink, ClickHouse con Keeper, Cube Store, PostgreSQL de metadatos y dbt.
- **S3 Administración:** el bastión, el gestor de secretos, la observabilidad (Prometheus, Loki y Grafana) y los respaldos.

Se puede simular en una sola máquina con Docker: **un proyecto de Compose por servidor** y **una red Docker por cada regla de cortafuegos**. Los mismos archivos sirven después para pasar a 3 VM.

**Aclaraciones al leer el PDF**

- **La fuente:** la portada habla de un *pipeline* S3/Redshift por VPN, con puertos 5432/3306. Las láminas de detalle dicen RDS/Aurora PostgreSQL por Internet con TLS 1.2+ y solo el puerto 5432. Esta guía sigue las láminas de detalle; hay que confirmarlo con EMPRESAX.
- **El modelo analítico:** la lámina que lo muestra rotula las capas con «Server 1/2/3/External». No significa que cada capa viva en un servidor distinto: crudo, estado vigente y preparado están todos en ClickHouse, en S2. La semántica y la caché se reparten entre S1 (API de Cube) y S2 (Cube Store).
- **La capa semántica:** el PDF la pone en S1 («API SQL/REST, refresco de preagregaciones») y deja la caché y las preagregaciones en S2. Por eso Cube se parte en dos: la API y el refresh worker en S1, y Cube Store en S2.

## 2. Distribución por servidor

### Servidor 1 · Aplicaciones (producción: 16 vCPU · 48 GB · 200 GB SSD)

| Componente en el PDF | Herramienta (informe) | Bloque de recursos | Notas |
|---|---|---|---|
| Proxy inverso / WAF (termina TLS) | Nginx + ModSecurity con reglas OWASP CRS | Reserva garantizada (6 vCPU · 12 GB) | Única entrada: puerto 443 |
| Servicio de autorización | Backend del portal (Node) | Reserva garantizada | Perfiles, guest tokens, JWT RS256 de 120 s para Cube, auditoría de exportaciones |
| Proveedor de identidad | Keycloak 26 (realm `bi`) | Reserva garantizada | OIDC/SAML, MFA, federación con el OIDC de la empresa |
| Portal frontend | React compilado, servido por Nginx | Límite máximo, prioridad menor | Catálogo y selector de perfil |
| Servidor de visualización | Superset + Redis (caché de Superset) | Límite máximo | Dashboards embebidos por token |
| Capa semántica | Cube API + Cube refresh worker | Límite máximo | SQL API para Superset, REST para el portal |
| (operación) | Agente Grafana Alloy | — | Envía logs y métricas a S3 |

### Servidor 2 · Datos (producción: 24 vCPU · 72 GB · 500 GB NVMe)

| Componente en el PDF | Herramienta (informe) | Notas |
|---|---|---|
| 1. Ejecutor de conectores | Kafka Connect con Debezium (PostgreSQL) y el sink oficial de ClickHouse | Único servicio con salida hacia AWS; disco separado para fsync |
| 2. Bus de eventos | Kafka (KRaft) | Retención de 7 días |
| 3. Almacén analítico | ClickHouse + ClickHouse Keeper | Reserva fija de 8 vCPU · 32 GB; Keeper guarda el estado KeeperMap del sink (exactamente una vez) |
| (preparación) | dbt Core + dbt-clickhouse, con su planificador | Construye `stg` y `mart` |
| 4. Caché y preagregaciones | Cube Store | Lo llena el refresh worker de S1 |
| 5. Base de metadatos | PostgreSQL con 3 bases aisladas | `keycloak`, `superset` y `portal` (registro de perfiles y auditoría), cada una con su usuario |
| (operación) | Agente Grafana Alloy | Envía a S3 |

S2 no publica ningún puerto: ni usuarios ni administradores entran directo.

### Servidor 3 · Administración (producción: 8 vCPU · 32 GB · 500 GB SSD)

| Componente en el PDF | Herramienta | Notas |
|---|---|---|
| Bastión | OpenSSH con MFA (TOTP por PAM) y grabación de sesiones (tlog) | Única vía de administración |
| Gestor de secretos | OpenBao (bifurcación libre de Vault); el informe menciona «Vault o SOPS» | Rotación cada 90 días, desbloqueo con claves repartidas entre dos personas (custodia dual) |
| Métricas y logs | Prometheus + Alertmanager, Loki, Grafana | Reciben en modo solo-anexar; Grafana se abre por túnel SSH del bastión |
| Respaldos | `pg_dump` + `BACKUP` nativo de ClickHouse + restic (cifrado) | Hacia un repositorio externo inmutable (S3 con *object lock*) |

## 3. Flujos permitidos entre servidores

Todo lo que no está en esta tabla queda denegado por defecto. En el laboratorio, cada fila es una red Docker.

| Regla | Desde | Hacia | Para qué | Red en el laboratorio |
|---|---|---|---|---|
| Usuarios → S1 | Navegador | Proxy (443) | Portal, Keycloak y Superset embebido | `bi_publica` |
| S1 → S2 metadatos | Keycloak, backend, Superset | PostgreSQL de metadatos (5432) | Cada uno a su propia base | `bi_meta` |
| S1 → S2 analítico | Cube API y refresh worker | ClickHouse (8123), Cube Store | Solo `cube_ro`, lectura de `mart` | `bi_semantica` |
| S2 → AWS | Kafka Connect | RDS/Aurora (5432, TLS verify-full) | Captura de cambios | `bi_aws` |
| S1/S2 → S3 | Agentes Alloy | Prometheus (remote-write), Loki | Logs y métricas solo-anexar | `bi_telemetria` |
| S3 → S2 | Respaldos | PostgreSQL de metadatos, ClickHouse | Copias diarias | `bi_respaldos` |
| S3 → externo | Respaldos | Repositorio inmutable | Copias cifradas | `bi_repositorio` |
| TI → S3 | Administrador | Bastión (SSH) | Única entrada administrativa | `bi_gestion` |

**Superset no tiene ninguna ruta hacia ClickHouse:** todo consumo pasa por Cube, como exige el PDF.

## 4. Cómo simular los 3 servidores en Docker

**El enfoque: un proyecto por servidor y una red por regla.** Cada servidor es una carpeta con su propio `docker-compose.yml` y su nombre de proyecto (`bi-s1`, `bi-s2`, `bi-s3`). Además hay un cuarto proyecto, `bi-aws`, que hace de RDS mientras no haya acceso a la base real. Las redes se crean antes, fuera de los proyectos, con `crear-redes.sh`.

```
lab-3-servidores/
├── crear-redes.sh
├── aws-simulado/docker-compose.yml   # rds-simulado (PostgreSQL con wal_level=logical)
├── s2-datos/docker-compose.yml       # se levanta primero
├── s1-app/docker-compose.yml
└── s3-admin/docker-compose.yml
```

**Cómo se respeta el aislamiento**

- **Puertos publicados:** solo el proxy de S1 publica puertos (443 y 80 para redirigir). En S3, el bastión publica solo en `127.0.0.1:2222`. S2 no publica nada.
- **Redes internas:** las creadas con `--internal` no tienen salida a Internet. Solo `bi_publica`, `bi_aws` y `bi_gestion` la tienen. Así, S2 solo puede salir por `bi_aws`, y en ella está únicamente Kafka Connect.
- **Pertenencia a las redes:** un contenedor solo ve a otro si comparten una red. Keycloak está en `bi_meta` pero no en `bi_semantica`, así que no alcanza ClickHouse.
- **Secretos:** en el laboratorio siguen en el `.env`. En el modelo final, el administrador los saca de OpenBao desde el bastión al desplegar. OpenBao no queda en una red compartida con S1 ni S2.

**Recursos.** Cada servicio lleva su límite de CPU y memoria (`cpus`, `mem_limit`), repartidos en proporción al PDF:

| «Servidor» | Producción | Límites en el laboratorio |
|---|---|---|
| S1 | 16 vCPU · 48 GB | ~5,5 vCPU · 6,6 GB |
| S2 | 24 vCPU · 72 GB | ~5,5 vCPU · 8,5 GB |
| S3 | 8 vCPU · 32 GB | ~2,4 vCPU · 2,9 GB |

Los límites son un techo, no el consumo real. Para tener todo levantado conviene una VM de al menos 8 vCPU y 16 GB; con 24 GB va holgado.

**Comandos base**

```bash
cd lab-3-servidores
cp ../.env .env
bash crear-redes.sh
docker build -t bi-connect:3.4.3.Final ../infra/connect
docker build -t bi-dbt:1.10.3        ../dbt
docker build -t bi-superset:6.1.0    ../superset

docker compose -p bi-aws --env-file .env -f aws-simulado/docker-compose.yml up -d
docker compose -p bi-s2  --env-file .env -f s2-datos/docker-compose.yml   up -d
docker compose -p bi-s1  --env-file .env -f s1-app/docker-compose.yml     up -d
docker compose -p bi-s3  --env-file .env -f s3-admin/docker-compose.yml   up -d
```

**Cómo comprobar que el aislamiento funciona**

```bash
# Superset NO debe llegar a ClickHouse (debe fallar)
docker compose -p bi-s1 -f s1-app/docker-compose.yml exec superset \
  python -c "import socket; socket.create_connection(('clickhouse', 8123), 3)"
# Cube SÍ debe llegar (debe responder Ok.)
docker compose -p bi-s1 -f s1-app/docker-compose.yml exec cube-api \
  node -e "fetch('http://clickhouse:8123/ping').then(r => r.text()).then(console.log)"
# S2 no tiene salida a Internet (ClickHouse no resuelve nombres externos)
docker compose -p bi-s2 -f s2-datos/docker-compose.yml exec clickhouse \
  sh -c "getent hosts example.com || echo 'sin salida: correcto'"
# Connect sí llega a la fuente por bi_aws
docker compose -p bi-s2 -f s2-datos/docker-compose.yml exec connect \
  bash -c "exec 3<>/dev/tcp/fuente/5432 && echo 'llega a la fuente: correcto'"
```

## 5. Orden de armado por fases

| Fase | Qué se levanta | Servidor | Cómo se verifica |
|---|---|---|---|
| 1 · Base e identidad | Redes, `postgres-meta`, Keycloak, backend, portal, proxy | S2 + S1 | Login en `https://bi.localhost` y catálogo por perfil |
| 2 · Captura de datos | `rds-simulado`, Kafka, Connect, Keeper, ClickHouse | AWS + S2 | Conectores en RUNNING y conteos iguales entre fuente y `raw_erp` |
| 3 · Transformación | `dbt-planificador` | S2 | `dbt build` sin fallos; `stg` y `mart` poblados |
| 4 · Semántica | Cube Store (S2), Cube API y refresh worker (S1) | S1 + S2 | Consulta por la SQL API con `cube_comercial` |
| 5 · Visualización | Redis y Superset | S1 | Dashboard embebido en el portal |
| 6 · Gobierno | Bastión, OpenBao, Prometheus, Loki, Grafana, respaldos y repositorio | S3 | Paneles con datos, respaldo y restauración probados |
| 7 · Endurecimiento | TLS interno con una CA de laboratorio, WAF con reglas OWASP, `sslmode=verify-full`, sink con `exactlyOnce` | Todos | Pruebas de la matriz Zero-Trust |

Cada fase se cierra antes de pasar a la siguiente, igual que en el cronograma. La fase 1 es lo que ya funciona en tu VM, reubicado: tu Postgres actual pasa a ser `postgres-meta` en S2.

## 6. Límites de la simulación y paso a 3 VM y producción

**Lo que Docker en una sola máquina no puede simular**

- **La dirección de la conexión:** una red Docker deja que sus miembros se hablen en los dos sentidos. Para imponer «S1 → S2 sí, S2 → S1 no» hacen falta reglas `iptables` en la cadena `DOCKER-USER`, o los cortafuegos reales.
- **El bastión como única vía:** en una sola máquina, quien tiene acceso a `docker` administra todo. El bastión solo cumple su papel con 3 máquinas separadas.
- **La telemetría:** los agentes leen `docker.sock` y ven los contenedores de los tres «servidores».
- **Los límites de recursos:** Docker limita contenedores, no un servidor completo. Las reservas garantizadas del PDF (por ejemplo, 6 vCPU para el bloque crítico de S1) se aproximan con límites por servicio.

**El siguiente paso: 3 VM**

1. Crear 3 VM Ubuntu (Multipass, VirtualBox o la plataforma de virtualización de la empresa) con los tamaños escalados.
2. Copiar a cada VM solo su carpeta (`s1-app`, `s2-datos` o `s3-admin`).
3. Reemplazar las redes compartidas por **IP y puertos reales**: por ejemplo, `CUBEJS_DB_HOST=10.0.2.20` en lugar de `clickhouse`. Cada red del laboratorio se convierte en una regla `ufw` o `nftables`.
4. Activar TLS interno (fase 7) y el bastión como única entrada SSH.

**En producción**

- **S2 hacia AWS:** sale por la IP pública fija del NAT de la empresa, solo al puerto 5432 del endpoint.
- **Secretos:** OpenBao los entrega en el arranque; dejan de vivir en el `.env`.
- **Respaldos:** van a un repositorio corporativo con bloqueo de objetos, no a MinIO local.

## 7. Fuentes

- Arquitectura de Plataforma BI v3.0 (PDF, 15 páginas): láminas de macrotopología, servidores 1, 2 y 3, extracción desde AWS, matriz Zero-Trust y modelo analítico.
- Informe técnico de implementación, plataforma BI web con software abierto (v3.0): herramientas por capa, cuentas de ClickHouse, Cube (API, refresh worker y Cube Store separados), observabilidad y respaldos (secciones 6, 7, 10 y 15).
- Archivos del laboratorio: `lab-3-servidores/` (validados con `docker compose config`).
