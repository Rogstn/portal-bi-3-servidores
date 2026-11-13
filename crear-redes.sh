#!/bin/bash
# =============================================================================
# Crea las redes Docker que simulan el cableado y el cortafuegos entre los
# 3 servidores de la arquitectura v3.0. Se ejecuta UNA vez, antes de levantar
# cualquier servidor. Es idempotente.
#
#   bi_publica      usuarios -> S1: solo el proxy (443)
#   bi_s1           red interna de S1 (aplicaciones)
#   bi_s2           red interna de S2 (datos)                       sin salida
#   bi_s3           red interna de S3 (administración)              sin salida
#   bi_meta         S1 -> S2: Keycloak, backend y Superset -> PostgreSQL de metadatos
#   bi_semantica    S1 -> S2: Cube API y refresh worker -> ClickHouse (solo mart) y Cube Store
#   bi_telemetria   S1/S2 -> S3: agentes -> Prometheus y Loki (solo-anexar)
#   bi_respaldos    S3 -> S2: respaldos -> PostgreSQL de metadatos y ClickHouse
#   bi_repositorio  S3 -> repositorio externo inmutable
#   bi_aws          S2 -> AWS: única salida, solo Kafka Connect
#   bi_gestion      TI -> S3: solo el bastión
#
# --internal = la red no tiene salida a Internet (como un segmento sin ruta).
# =============================================================================
set -euo pipefail

crear() {
  local nombre="$1"; shift
  if docker network inspect "$nombre" > /dev/null 2>&1; then
    echo "  ya existe: $nombre"
  else
    docker network create "$@" "$nombre" > /dev/null
    echo "  creada:    $nombre $*"
  fi
}

crear bi_publica
crear bi_s1          --internal
crear bi_s2          --internal
crear bi_s3          --internal
crear bi_meta        --internal
crear bi_semantica   --internal
crear bi_telemetria  --internal
crear bi_respaldos   --internal
crear bi_repositorio --internal
crear bi_aws         # NO interna: es la única con salida (S2 -> AWS)
crear bi_gestion     # NO interna: por aquí entra el administrador al bastión

echo "Redes listas."
