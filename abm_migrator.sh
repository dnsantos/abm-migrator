#!/bin/bash

# ==============================================================================
# CARREGAR CONFIGURAÇÕES E AMBIENTE
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Verifica arquivo de config
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}❌ Erro: Arquivo 'config.env' não encontrado.${NC}"
    echo "ℹ️  Copie o 'config.env.example' para 'config.env' e preencha seus dados."
    exit 1
fi

source "$CONFIG_FILE"

# Verifica se as variáveis foram carregadas
if [ "$CLIENT_ID" == "INSIRA_SEU_CLIENT_ID_AQUI" ] || [ -z "$CLIENT_ID" ]; then
    echo -e "${RED}❌ Erro: Configure o CLIENT_ID no arquivo config.env${NC}"
    exit 1
fi

PRIVATE_KEY_PATH="$SCRIPT_DIR/$PEM_FILENAME"

if [ ! -f "$PRIVATE_KEY_PATH" ]; then
    echo -e "${RED}❌ Erro: Chave privada ($PEM_FILENAME) não encontrada na pasta do script.${NC}"
    exit 1
fi

# Ajuste automático da chave (EC -> PRIVATE) se necessário
sed -i '' 's/BEGIN EC PRIVATE KEY/BEGIN PRIVATE KEY/g' "$PRIVATE_KEY_PATH" 2>/dev/null
sed -i '' 's/END EC PRIVATE KEY/END PRIVATE KEY/g' "$PRIVATE_KEY_PATH" 2>/dev/null

# ==============================================================================
# HELP E ARGUMENTOS
# ==============================================================================

MODE="$1"
INPUT="$2"
TARGET_ARG="$3"

show_help() {
    echo "=============================================================================="
    echo "🍏 APPLE BUSINESS MANAGER - MIGRATOR TOOL"
    echo "=============================================================================="
    echo "Uso: $0 [MODO] [ARGUMENTOS...]"
    echo ""
    echo "  check [SERIAL/ARQUIVO]       Consulta status e MDM atual."
    echo "  list                         Lista servidores MDM e seus IDs."
    echo "  assign [FONTE] [ID_MDM]      Atribui dispositivo(s) ao MDM de destino."
    echo "  release [FONTE] [ID_MDM]     ⚠️  REMOVE dispositivos do servidor MDM."
    echo ""
    echo "  * [FONTE] pode ser um Serial Único ou um Arquivo .txt"
    echo "=============================================================================="
}

if [ -z "$MODE" ] || [[ "$MODE" == *"help"* ]]; then
    show_help
    exit 0
fi

# ==============================================================================
# AUTENTICAÇÃO
# ==============================================================================

# Verifica dependências Python
python3 -c "import jwt, cryptography" 2>/dev/null
if [ $? -ne 0 ]; then
    echo -e "${YELLOW}⚠️  Instalando dependências Python...${NC}"
    pip3 install -r "$SCRIPT_DIR/requirements.txt" --user >/dev/null
fi

echo "--- 🔑 Gerando Token de Acesso..."

# Exporta variaveis para o Python
export P_KEY_PATH="$PRIVATE_KEY_PATH"
export P_CLIENT_ID="$CLIENT_ID"
export P_KEY_ID="$KEY_ID"

JWT=$(python3 -c "
import os, sys, time, uuid, jwt
from cryptography.hazmat.primitives import serialization

try:
    with open(os.environ['P_KEY_PATH'], 'rb') as f: key_data = f.read().strip()
    private_key = serialization.load_pem_private_key(key_data, password=None)
    current_time = int(time.time()) - 60
    payload = {
        'iss': os.environ['P_CLIENT_ID'],
        'sub': os.environ['P_CLIENT_ID'],
        'aud': 'https://account.apple.com/auth/oauth2/v2/token',
        'iat': current_time,
        'exp': current_time + 1800,
        'jti': str(uuid.uuid4())
    }
    print(jwt.encode(payload, private_key, algorithm='ES256', headers={'kid': os.environ['P_KEY_ID'], 'alg': 'ES256'}))
except Exception as e:
    sys.exit(1)
")

if [ -z "$JWT" ]; then
    echo -e "${RED}❌ Erro crítico: Falha ao assinar JWT.${NC}"
    exit 1
fi

TOKEN_RES=$(curl -s -X POST "https://account.apple.com/auth/oauth2/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=$CLIENT_ID&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer&client_assertion=$JWT&scope=business.api")

ACCESS_TOKEN=$(echo $TOKEN_RES | python3 -c "import sys, json; print(json.load(sys.stdin).get('access_token', ''))")

if [ -z "$ACCESS_TOKEN" ]; then
    echo -e "${RED}❌ Erro Login: $TOKEN_RES${NC}"
    exit 1
fi

# ==============================================================================
# LÓGICA
# ==============================================================================

# --- CHECK (VERSÃO BLINDADA COM SHLEX) ---
if [ "$MODE" == "check" ]; then
    if [ -z "$INPUT" ]; then
        echo -e "${RED}Informe o serial ou arquivo .txt${NC}"
        exit 1
    fi

    if [ -f "$INPUT" ]; then
        echo "--- 📂 Modo Arquivo: Lendo seriais de '$INPUT' ---"
        SERIAL_LIST=$(grep -vE "^\s*$" "$INPUT")
    else
        SERIAL_LIST="$INPUT"
    fi

    for CURRENT_SERIAL in $SERIAL_LIST; do
        CURRENT_SERIAL=$(echo "$CURRENT_SERIAL" | xargs)
        [ -z "$CURRENT_SERIAL" ] && continue

        echo ""
        echo ">>> 🔍 Consultando: $CURRENT_SERIAL"

        DEVICE_JSON=$(curl -s -X GET "https://api-business.apple.com/v1/orgDevices/$CURRENT_SERIAL" \
            -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json")

        # Limpa variáveis antes de processar
        DEVICE_MODEL=""
        DEVICE_STATUS=""
        SERVER_URL=""
        API_ERROR=""

        # Python apenas define VARIÁVEIS, não roda comandos ECHO (Muito mais seguro)
        eval $(echo "$DEVICE_JSON" | python3 -c "
import sys, json, shlex

try:
    raw = json.load(sys.stdin)
    if 'errors' in raw:
        err = raw['errors'][0]
        code = str(err.get('code', 'Unknown'))
        title = str(err.get('title', 'Error'))
        print(f'API_ERROR={shlex.quote(code + \" - \" + title)}')
    else:
        data = raw.get('data', {})
        attrs = data.get('attributes', {})
        rels = data.get('relationships', {})
        
        # shlex.quote blinda a string para o bash (trata aspas, espaços, etc)
        print(f'DEVICE_MODEL={shlex.quote(str(attrs.get(\"deviceModel\", \"N/A\")))}')
        print(f'DEVICE_STATUS={shlex.quote(str(attrs.get(\"status\", \"N/A\")))}')
        
        if 'assignedServer' in rels:
            link = rels['assignedServer']['links']['related']
            print(f'SERVER_URL={shlex.quote(link)}')

except Exception as e:
    print(f'API_ERROR={shlex.quote(\"Erro JSON: \" + str(e))}')
")

        # Agora o Bash decide o que mostrar baseado nas variáveis que o Python preencheu
        if [ ! -z "$API_ERROR" ]; then
            echo -e "❌ Erro API: $API_ERROR"
        else
            echo -e "✅ Modelo: $DEVICE_MODEL"
            echo -e "✅ Status: $DEVICE_STATUS"

            if [ ! -z "$SERVER_URL" ]; then
                SERVER_JSON=$(curl -s -X GET "$SERVER_URL" -H "Authorization: Bearer $ACCESS_TOKEN")
                # Extração simples do nome do servidor
                MDM_NAME=$(echo "$SERVER_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin).get('data',{}).get('attributes',{}).get('serverName','Desconhecido'))")
                echo -e "✅ MDM: $MDM_NAME"
            else
                echo -e "⚠️  Sem MDM atribuído."
            fi
        fi
    done
    exit 0
fi

if [ "$MODE" == "list" ]; then
    echo "--- 📋 Servidores MDM Disponíveis ---"
    curl -s -X GET "https://api-business.apple.com/v1/mdmServers" -H "Authorization: Bearer $ACCESS_TOKEN" |
        python3 -c "import sys, json; [print(f'{i[\"attributes\"][\"serverName\"]:<30} | {i[\"id\"]}') for i in json.load(sys.stdin)['data']]"
    exit 0
fi

if [ "$MODE" == "assign" ]; then
    # Valida se os argumentos foram passados
    if [ -z "$INPUT" ] || [ -z "$TARGET_ARG" ]; then
        echo -e "${RED}Uso: $0 assign [ARQUIVO_OU_SERIAL] [ID_MDM]${NC}"
        exit 1
    fi

    export P_TARGET="$TARGET_ARG"

    # 🧠 LÓGICA HÍBRIDA: Arquivo vs Serial Único
    if [ -f "$INPUT" ]; then
        # É um arquivo: Caminho normal
        export P_FILE="$INPUT"
        export P_MODE="FILE"
        echo "--- 📦 Modo Arquivo: Lendo seriais de '$INPUT'..."
    else
        # Não é arquivo: Assume que é um Serial Único
        export P_SERIAL="$INPUT"
        export P_MODE="SINGLE"
        echo "--- 🎯 Modo Único: Migrando serial '$INPUT'..."
    fi

    # Python agora decide se lê do arquivo ou usa a variável direta
    PAYLOAD=$(python3 -c "
import os, json, sys

mode = os.environ['P_MODE']
target = os.environ['P_TARGET']
serials = []

try:
    if mode == 'FILE':
        with open(os.environ['P_FILE'], 'r') as f:
            serials = [l.strip() for l in f if l.strip()]
    else:
        # Modo Single: Lista com um único item
        serials = [os.environ['P_SERIAL']]

    if not serials:
        print('EMPTY')
        sys.exit(0)

    # Monta o JSON padrão da Apple
    data = {
        'data': {
            'type': 'orgDeviceActivities',
            'attributes': {
                'activityType': 'ASSIGN_DEVICES'
            },
            'relationships': {
                'mdmServer': {
                    'data': {
                        'type': 'mdmServers',
                        'id': target
                    }
                },
                'devices': {
                    'data': [{'type': 'orgDevices', 'id': s} for s in serials]
                }
            }
        }
    }
    print(json.dumps(data))
except Exception as e:
    print('ERROR')
")

    if [ "$PAYLOAD" == "EMPTY" ]; then
        echo "❌ Erro: Nenhum serial válido encontrado."
        exit 1
    elif [ "$PAYLOAD" == "ERROR" ]; then
        echo "❌ Erro interno ao gerar JSON."
        exit 1
    fi

    # Envia para a Apple
    echo "--- 🚀 Enviando requisição para a Apple..."
    curl -s -X POST "https://api-business.apple.com/v1/orgDeviceActivities" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" |
        python3 -c "import sys, json; d=json.load(sys.stdin); print('✅ SUCESSO! Migração concluída.' if 'data' in d else f'❌ FALHA: {d}')"

    exit 0
fi

# --- RELEASE / UNASSIGN (REMOVER VÍNCULO DO ABM) ---
if [ "$MODE" == "release" ]; then
    # Valida se os argumentos foram passados (Agora exige o TARGET_ARG)
    if [ -z "$INPUT" ] || [ -z "$TARGET_ARG" ]; then
        echo -e "${RED}Uso: $0 release [ARQUIVO_OU_SERIAL] [ID_MDM_ATUAL]${NC}"
        echo "ℹ️  A Apple exige o ID do servidor atual para confirmar a remoção."
        exit 1
    fi

    export P_TARGET="$TARGET_ARG"

    if [ -f "$INPUT" ]; then
        export P_FILE="$INPUT"
        export P_MODE="FILE"
        COUNT=$(grep -cve '^\s*$' "$INPUT")
        MSG="Você está prestes a DESVINCULAR $COUNT dispositivos do servidor ($TARGET_ARG)."
    else
        export P_SERIAL="$INPUT"
        export P_MODE="SINGLE"
        MSG="Você está prestes a DESVINCULAR o serial $INPUT do servidor ($TARGET_ARG)."
    fi

    # --- TRAVA DE SEGURANÇA ---
    echo -e "${RED}⚠️  ATENÇÃO: O dispositivo ficará como 'Unassigned' no ABM.${NC}"
    echo "$MSG"
    echo "Isso impede que o dispositivo faça o Enrollment automático no Jamf."
    read -p "Confirma a desvinculação? (y/N): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "Operação cancelada."
        exit 0
    fi
    # --------------------------

    PAYLOAD=$(python3 -c "
import os, json, sys

mode = os.environ['P_MODE']
target = os.environ['P_TARGET']
serials = []

try:
    if mode == 'FILE':
        with open(os.environ['P_FILE'], 'r') as f:
            serials = [l.strip() for l in f if l.strip()]
    else:
        serials = [os.environ['P_SERIAL']]

    if not serials:
        print('EMPTY')
        sys.exit(0)

    data = {
        'data': {
            'type': 'orgDeviceActivities',
            'attributes': {
                'activityType': 'UNASSIGN_DEVICES' 
            },
            'relationships': {
                'mdmServer': {
                    'data': {
                        'type': 'mdmServers',
                        'id': target # Apple exige o ID de origem aqui
                    }
                },
                'devices': {
                    'data': [{'type': 'orgDevices', 'id': s} for s in serials]
                }
            }
        }
    }
    print(json.dumps(data))
except: print('ERROR')
")

    if [ "$PAYLOAD" == "EMPTY" ]; then
        echo "Erro: Nenhum serial válido."
        exit 1
    fi
    if [ "$PAYLOAD" == "ERROR" ]; then
        echo "Erro interno JSON."
        exit 1
    fi

    echo "--- 🗑️  Enviando comando de UNASSIGN para a Apple..."
    curl -s -X POST "https://api-business.apple.com/v1/orgDeviceActivities" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" |
        python3 -c "import sys, json; d=json.load(sys.stdin); print('✅ SUCESSO! Dispositivos desvinculados (Unassigned).' if 'data' in d else f'❌ FALHA: {d}')"

    exit 0
fi
