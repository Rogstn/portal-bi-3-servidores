# Laboratorio de 3 servidores en Docker (arquitectura v3.0)

Simula en **una sola máquina** los tres servidores de la arquitectura v3.0. Cada servidor es un proyecto de Docker Compose, y las redes Docker hacen de cortafuegos: cada red es **una regla permitida**.

```
plataforma-bi/                 <- tu repositorio
└── lab-3-servidores/
    ├── crear-redes.sh         <- crea las redes (una vez)
    ├── aws-simulado/          <- hace de RDS/Aurora PostgreSQL
    ├── s2-datos/              <- Servidor 2 (se levanta primero)
    ├── s1-app/                <- Servidor 1
    └── s3-admin/              <- Servidor 3
```

Los compose usan rutas `../../` hacia las carpetas del repositorio (`infra/`, `cdc/`, `dbt/`, `cube/`, `superset/`, `backend/`, `portal/`), así que esta carpeta va **dentro** del repositorio.

## Redes = reglas de cortafuegos

| Red | Regla que representa | Quién está |
|---|---|---|
| `bi_publica` | Usuarios → S1 (443) | proxy |
| `bi_meta` | S1 → S2 metadatos | keycloak, backend, superset · postgres-meta |
| `bi_semantica` | S1 → S2 datos analíticos | cube-api, cube-refresh-worker · clickhouse, cubestore |
| `bi_telemetria` | S1/S2 → S3 logs y métricas | agentes · prometheus, loki |
| `bi_respaldos` | S3 → S2 respaldos | respaldos · postgres-meta, clickhouse |
| `bi_repositorio` | S3 → repositorio externo | respaldos · repositorio (MinIO) |
| `bi_aws` | S2 → AWS (única salida) | connect · rds-simulado |
| `bi_gestion` | TI → bastión | bastion |
| `bi_s1`, `bi_s2`, `bi_s3` | Tráfico interno de cada servidor | — |

Todas son `--internal` (sin salida a Internet) salvo `bi_publica`, `bi_aws` y `bi_gestion`.

## Orden de arranque

```bash
cd lab-3-servidores
cp ../.env .env                      # mismas variables del repositorio
bash crear-redes.sh
docker compose -p bi-aws --env-file .env -f aws-simulado/docker-compose.yml up -d
docker compose -p bi-s2  --env-file .env -f s2-datos/docker-compose.yml up -d postgres-meta
docker compose -p bi-s1  --env-file .env -f s1-app/docker-compose.yml up -d proxy keycloak backend portal
# ...y se van sumando servicios por fase (ver la guía)
```

Las imágenes propias se construyen antes desde el repositorio:

```bash
docker build -t bi-connect:3.4.3.Final infra/connect
docker build -t bi-dbt:1.10.3         dbt
docker build -t bi-superset:6.1.0     superset
```

## Límites de lo que simula Docker

- Las redes deciden **quién ve a quién**, pero no la **dirección** de la conexión. Para eso hacen falta reglas `iptables` en la cadena `DOCKER-USER`, o los cortafuegos reales.
- En una sola máquina, quien tenga acceso a `docker` administra los tres «servidores». El bastión solo se vuelve la única vía de administración cuando hay 3 máquinas (VM) separadas.
- Los agentes leen `docker.sock` y en una sola máquina ven los contenedores de todos los servidores.
- Los límites de CPU y memoria son por contenedor; Docker no limita un «servidor» completo.
