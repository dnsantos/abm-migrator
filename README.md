# 🍏 ABM Migrator Tool

[![Bash](https://img.shields.io/badge/Language-Bash-4EAA25?style=flat&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Python](https://img.shields.io/badge/Python-3.x-blue?style=flat&logo=python&logoColor=white)](https://www.python.org/)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**ABM Migrator** é uma ferramenta de linha de comando (CLI) desenvolvida para administradores Apple (MacAdmins) que precisam gerenciar dispositivos no **Apple Business Manager** de forma ágil e automatizada.

Ao contrário da interface web do ABM, que pode ser lenta para grandes volumes, este script utiliza a API oficial da Apple para realizar consultas instantâneas e migrações em massa entre servidores MDM.

## 🚀 Funcionalidades

* **🔍 Check Device:** Consulta o status de um serial, retornando o Modelo, Status (Added/Removed) e o Servidor MDM atual.
* **📋 List Servers:** Lista todos os servidores MDM cadastrados na organização e exibe seus UUIDs.
* **📦 Batch Migration:** Lê uma lista de seriais (`.txt`) e move todos os dispositivos para um servidor MDM de destino em uma única requisição.
* **🔐 Secure:** As credenciais e chaves privadas permanecem locais e nunca são compartilhadas.

---

## 🛠️ Pré-requisitos

* macOS ou Linux.
* Python 3 instalado (para assinatura do JWT).
* Acesso de Administrador ao Apple Business Manager para gerar as chaves de API.

---

## ⚙️ Instalação e Configuração

### 1. Clone o repositório
```bash
git clone [https://github.com/dnsantos/abm-migrator](https://github.com/dnsantos/abm-migrator)
cd abm-migrator

```

### 2. Instale as dependências

O script utiliza Python para criptografia segura do token de sessão.

```bash
pip3 install -r requirements.txt

```

### 3. Obtenha suas credenciais no Apple Business Manager

1. Logue no [Apple Business Manager](https://business.apple.com/).
2. Vá em **Preferências** > **Seu Nome** (Perfil).
3. Gere e baixe a **Chave Privada (.pem)** para a API.
4. Anote o **Client ID** (UUID da organização) e o **Key ID**.

### 4. Configure o ambiente

Copie o template de configuração e edite com seus dados:

```bash
cp config.env.example config.env
nano config.env

```

* Preencha o `CLIENT_ID` e `KEY_ID`.
* Coloque o arquivo `.pem` baixado dentro da pasta do projeto.
* Indique o nome do arquivo no campo `PEM_FILENAME`.

⚠️ **Importante:** O arquivo `config.env` e sua chave `.pem` são adicionados automaticamente ao `.gitignore` para evitar vazamento de credenciais.

---

## 📖 Como Usar

Dê permissão de execução ao script:

```bash
chmod +x abm_migrator.sh

```

### 1. Listar Servidores MDM

Use este comando para descobrir o ID (UUID) do servidor para onde você quer enviar os dispositivos.

```bash
./abm_migrator.sh list

```

*Saída:*

```text
NOME DO SERVIDOR               | ID (UUID)
---------------------------------------------------------------------------
Jamf Pro Production            | 422079C2-8231-4113-8E53-XXXXXXXXXXXX
Microsoft Intune               | 8B1123A1-9922-4221-7F41-XXXXXXXXXXXX

```

### 2. Consultar um Dispositivo (Check)

Verifique onde um dispositivo está atrelado antes de movê-lo.

```bash
./abm_migrator.sh check C02XXXXXXX

```

### 3. Migração em Lote (Batch)

Crie um arquivo de texto (ex: `ipads_novos.txt`) com um Serial Number por linha. Depois, execute:

```bash
./abm_migrator.sh batch ipads_novos.txt 422079C2-8231-4113-8E53-XXXXXXXXXXXX

```

O script processará a lista e enviará para a Apple.

---

## 📂 Estrutura do Projeto

```text
abm-migrator/
├── abm_migrator.sh       # Script principal (Lógica e API)
├── config.env.example    # Template de configuração
├── requirements.txt      # Dependências Python (pyjwt, cryptography)
├── README.md             # Documentação
└── .gitignore            # Regras de segurança do Git

```

---

## 🛡️ Segurança

Este projeto foi desenhado seguindo práticas de "Blue Team":

1. **Zero Upload:** Chaves privadas nunca saem da sua máquina.
2. **JWT Assinado Localmente:** O token de autenticação é gerado localmente via Python e apenas o token temporário (Bearer) é enviado para a Apple.
3. **Ambiente Isolado:** As variáveis sensíveis são carregadas de um arquivo `.env` ignorado pelo Git.

---

## 🤝 Contribuição

Contribuições são bem-vindas! Sinta-se à vontade para abrir Issues ou enviar Pull Requests.

1. Faça um Fork do projeto
2. Crie uma Branch para sua Feature (`git checkout -b feature/IncrívelFeature`)
3. Faça o Commit (`git commit -m 'Add some IncrívelFeature'`)
4. Faça o Push (`git push origin feature/IncrívelFeature`)
5. Abra um Pull Request

## 📄 Licença

Distribuído sob a licença MIT. Veja `LICENSE` para mais informações.

```

```