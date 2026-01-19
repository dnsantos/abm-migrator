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
    echo "  check [SERIAL]               Consulta status e MDM atual do dispositivo."
    echo "  list                         Lista servidores MDM e seus IDs."
    echo "  batch [ARQUIVO] [ID_MDM]     Migra uma LISTA (.txt) para o MDM de destino."
    echo "  batch [SERIAL] [ID_MDM]      Migra um SERIAL ÚNICO para o MDM de destino."
    echo "  help                         Exibe esta ajuda."
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

if [ "$MODE" == "check" ]; then
    if [ -z "$INPUT" ]; then
        echo -e "${RED}Informe o serial.${NC}"
        exit 1
    fi

    echo "--- 🔍 Consultando: $INPUT ---"
    DEVICE_JSON=$(curl -s -X GET "https://api-business.apple.com/v1/orgDevices/$INPUT" \
        -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json")

    eval $(echo "$DEVICE_JSON" | python3 -c "
import sys, json
try:
    raw = json.load(sys.stdin)
    if 'errors' in raw:
        print('echo \"❌ Dispositivo não encontrado (404)\";')
        sys.exit(0)
    data = raw.get('data', {})
    attrs = data.get('attributes', {})
    rels = data.get('relationships', {})
    print(f'echo \"✅ Modelo: {attrs.get(\"deviceModel\")}\";')
    print(f'echo \"✅ Status: {attrs.get(\"status\")}\";')
    if 'assignedServer' in rels:
        print(f'SERVER_URL=\"{rels[\"assignedServer\"][\"links\"][\"related\"]}\"')
    else:
        print('echo \"⚠️  Sem MDM atribuído.\";')
except: pass
")
    if [ ! -z "$SERVER_URL" ]; then
        SERVER_JSON=$(curl -s -X GET "$SERVER_URL" -H "Authorization: Bearer $ACCESS_TOKEN")
        echo "$SERVER_JSON" | python3 -c "import sys, json; print(f'✅ MDM: {json.load(sys.stdin)[\"data\"][\"attributes\"][\"serverName\"]}')"
    fi
    exit 0
fi

if [ "$MODE" == "list" ]; then
    echo "--- 📋 Servidores MDM Disponíveis ---"
    curl -s -X GET "https://api-business.apple.com/v1/mdmServers" -H "Authorization: Bearer $ACCESS_TOKEN" |
        python3 -c "import sys, json; [print(f'{i[\"attributes\"][\"serverName\"]:<30} | {i[\"id\"]}') for i in json.load(sys.stdin)['data']]"
    exit 0
fi

if [ "$MODE" == "batch" ]; then
    # Valida se os argumentos foram passados
    if [ -z "$INPUT" ] || [ -z "$TARGET_ARG" ]; then
        echo -e "${RED}Uso: $0 batch [ARQUIVO_OU_SERIAL] [ID_MDM]${NC}"
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
