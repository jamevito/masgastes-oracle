#!/usr/bin/env bash
#
# Un intento de crear la instancia gratuita en Oracle. Lo llama el workflow de
# GitHub Actions cada 15 minutos. NO lleva bucle: una ejecucion, un intento.
#
# Espera en el entorno:
#   T        el OCID del tenancy (que para una cuenta gratuita es tambien el
#            compartimento raiz)
#   SSH_PUB  el contenido de tu clave publica
#   OCI_REGION, NOMBRE
#
set -uo pipefail

: "${T:?falta el tenancy}"
: "${SSH_PUB:?falta la clave publica}"
NOMBRE="${NOMBRE:-masgastes}"

salida() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/stdout}"; }

echo "$SSH_PUB" > /tmp/ssh.pub

# --------------------------------------------------------------------------
# 0. Si ya hay una maquina, no tocar nada.
#
# Esto no es cosmetico: sin esta comprobacion, el dia que Oracle suelte una
# instancia el workflow seguiria creando una mas cada 15 minutos, te saldrias
# del cupo Always Free y empezarian a facturarte. Es la guarda mas importante
# del fichero.
# --------------------------------------------------------------------------
vivas=$(oci compute instance list -c "$T" --all 2>/dev/null \
        | jq '[.data[]? | select(."lifecycle-state" | IN("RUNNING","PROVISIONING","STARTING","STOPPED","STOPPING"))] | length')
vivas=${vivas:-0}
if [ "$vivas" -gt 0 ]; then
  echo "Ya tienes $vivas instancia(s). No hago nada."
  salida creada no
  exit 0
fi

# --------------------------------------------------------------------------
# 1. Descubrir subnet, dominio de disponibilidad e imagen.
#    Se busca en cada ejecucion en vez de guardarlo: los OCID de las imagenes
#    de Ubuntu cambian cada vez que Canonical publica una nueva.
# --------------------------------------------------------------------------
SUBNET=$(oci network subnet list -c "$T" --all 2>/dev/null | jq -r '.data[0].id // empty')
[ -n "$SUBNET" ] || { echo "No encuentro ninguna subnet. ¿Creaste la VCN?"; salida creada no; exit 1; }

mapfile -t ADS < <(oci iam availability-domain list -c "$T" 2>/dev/null | jq -r '.data[].name')
[ "${#ADS[@]}" -gt 0 ] || { echo "No puedo listar los dominios de disponibilidad."; salida creada no; exit 1; }

# La ARM (1 OCPU / 6 GB) es ocho veces la micro y tambien es gratis, asi que se
# lleva 4 de cada 5 ejecuciones. La quinta va para la micro, sola: probar las
# dos seguidas hace que la segunda choque siempre contra el limitador de Oracle.
# El reparto sale del reloj, asi no hay que guardar ningun contador.
if [ $(( ($(date +%s) / 900) % 5 )) -eq 0 ]; then
  FORMA="VM.Standard.E2.1.Micro"; EXTRA=()
else
  FORMA="VM.Standard.A1.Flex";    EXTRA=(--shape-config '{"ocpus":1,"memoryInGBs":6}')
fi

IMG=$(oci compute image list -c "$T" \
        --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
        --shape "$FORMA" --sort-by TIMECREATED --sort-order DESC 2>/dev/null \
      | jq -r '.data[0].id // empty')
[ -n "$IMG" ] || { echo "Sin imagen de Ubuntu para $FORMA."; salida creada no; exit 0; }

# --------------------------------------------------------------------------
# 2. Un intento por dominio de disponibilidad.
# --------------------------------------------------------------------------
for AD in "${ADS[@]}"; do
  echo "Probando $FORMA en ${AD##*:}..."

  RES=$(oci compute instance launch \
          --compartment-id "$T" --availability-domain "$AD" \
          --shape "$FORMA" --image-id "$IMG" --subnet-id "$SUBNET" \
          --assign-public-ip true --display-name "$NOMBRE" \
          --ssh-authorized-keys-file /tmp/ssh.pub \
          --wait-for-state RUNNING "${EXTRA[@]}" 2>&1)
  RC=$?

  if [ $RC -eq 0 ]; then
    ID=$(echo "$RES" | jq -r '.data.id // empty')
    [ -n "$ID" ] || ID=$(oci compute instance list -c "$T" --display-name "$NOMBRE" \
                          --lifecycle-state RUNNING 2>/dev/null | jq -r '.data[0].id // empty')
    IP=$(oci compute instance list-vnics --instance-id "$ID" 2>/dev/null \
         | jq -r '.data[0]."public-ip" // empty')
    echo "CREADA. IP publica: $IP"
    salida creada si
    salida ip "$IP"
    salida forma "$FORMA"
    exit 0
  fi

  # Oracle escribe esto de varias formas ("Out of capacity", "Out of host
  # capacity.", "out of capacity for shape...") y cambia la redaccion cada dos
  # por tres, asi que comparamos en minusculas y sin exigir la frase exacta.
  LOW=$(printf '%s' "$RES" | tr '[:upper:]' '[:lower:]')
  case "$LOW" in
    *toomanyrequests*|*"too many requests"*)
      echo "Oracle nos limita ahora mismo. Se reintenta en la proxima vuelta." ;;
    *limitexceeded*|*"reached the limit"*|*"exceeded the service limit"*)
      echo "CUPO AGOTADO -- ya tienes instancias gratuitas creadas."
      echo "$RES"
      salida creada no
      exit 1 ;;
    *capacity*)
      echo "sin capacidad" ;;
    *)
      # No se para el workflow por esto: la proxima ejecucion vuelve a probar.
      # Si es un problema de verdad (credenciales, permisos) fallara siempre y
      # GitHub te mandara un correo avisando de que el workflow falla.
      echo "Error no reconocido:"
      echo "$RES"
      salida creada no
      exit 1 ;;
  esac
done

salida creada no
exit 0
