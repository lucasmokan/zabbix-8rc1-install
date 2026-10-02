# Instalação do Zabbix 8.0 RC1 (PostgreSQL 18 + TimescaleDB 2.29)

Script que faz a **instalação nova** do Zabbix 8.0 RC1 em um servidor Ubuntu limpo, com PostgreSQL, TimescaleDB, Apache e PHP-FPM.

Tutoriais em vídeo no canal **MOK Monitoramento** no YouTube.

> **Atenção:** o Zabbix 8.0 RC1 é uma versão de pré-lançamento. Use em laboratório e testes, não em produção.

## O que é instalado

| Componente | Versão |
|---|---|
| Zabbix server, frontend e agent 2 | 8.0 RC1 |
| PostgreSQL | 18 |
| TimescaleDB | série 2.29.x (a mais recente disponível no repositório) |
| Servidor web | Apache + PHP-FPM |
| Idioma | locale pt_BR instalado |

Testado em **Ubuntu 24.04** e **Ubuntu 26.04**, em instalação limpa (cerca de 3,3 GB de RAM e 4 vCPUs).

## Requisitos

- Ubuntu 24.04 ou 26.04, **recém-instalado e dedicado ao Zabbix**
- Acesso root (`sudo`) e internet
- Faça um snapshot da máquina antes, se for virtual

## Como usar

Baixe, **leia o script** e só então execute:

```bash
wget https://raw.githubusercontent.com/SEU_USUARIO/zabbix-8-install/main/zabbix-8.0-rc1-instalacao.sh
less zabbix-8.0-rc1-instalacao.sh
chmod +x zabbix-8.0-rc1-instalacao.sh
sudo ./zabbix-8.0-rc1-instalacao.sh
```

Ao final, o script mostra o endereço do frontend, o nome do banco, o usuário e a **senha do banco** (gerada aleatoriamente). Anote a senha. Ela também fica em `DBPassword` no `/etc/zabbix/zabbix_server.conf`:

```bash
grep ^DBPassword= /etc/zabbix/zabbix_server.conf
```

### Variáveis opcionais

| Variável | Padrão | Para que serve |
|---|---|---|
| `ZBX_DB_PASS` | gerada aleatoriamente | Define a senha do banco (letras, números e `. _ @ % + = -`) |
| `ZBX_PG_VER` | `18` | Versão major do PostgreSQL |
| `ZBX_TSDB_SERIES` | `2.29` | Série do TimescaleDB |
| `ZBX_RELEASE_URL` | detectado | URL do `.deb` do repositório Zabbix |

Exemplo:

```bash
sudo ZBX_DB_PASS='MinhaSenha.Forte-123' ZBX_PG_VER=17 ZBX_TSDB_SERIES=2.28 ./zabbix-8.0-rc1-instalacao.sh
```

## O que o script faz

1. Valida o sistema (root e Ubuntu 24.04 ou 26.04) e se os repositórios de PostgreSQL e TimescaleDB atendem sua versão do Ubuntu
2. Adiciona os repositórios do PostgreSQL (PGDG) e do TimescaleDB
3. Instala o PostgreSQL e o TimescaleDB nas versões escolhidas, aplica o `timescaledb-tune` e **trava** o TimescaleDB na série escolhida (`apt-mark hold`)
4. Adiciona o repositório do Zabbix 8.0 e instala server, frontend, Apache, PHP-FPM e agent 2
5. Cria o usuário e o banco `zabbix`, importa o esquema e cria as hypertables do TimescaleDB
6. Configura o `zabbix_server.conf` e os limites de conexão do PostgreSQL
7. Configura o Apache com PHP-FPM e os limites de PHP exigidos pelo Zabbix
8. Inicia e habilita os serviços e confere se o PHP está executando

## Depois da instalação

1. Abra `http://IP_DO_SERVIDOR/zabbix` e siga o assistente
2. No passo do banco de dados: tipo PostgreSQL, host `localhost`, porta `5432`, banco `zabbix`, usuário `zabbix` e a senha informada no final do script
3. Troque a senha do usuário padrão no primeiro acesso
4. Em **Administração > Limpeza (Housekeeping)**, confira que a substituição de período de histórico e tendências está ativa

## Avisos importantes

- **Só para instalação nova.** Se o usuário `zabbix` já existir no PostgreSQL, o script para sem alterar nada.
- **Servidor dedicado.** O script desabilita o `mod_php` do Apache e passa para `mpm_event` com PHP-FPM. Isso afeta outros sites PHP que usem `mod_php` na mesma máquina.
- **Versão do banco.** Não há garantia de que uma combinação diferente de PostgreSQL e TimescaleDB seja aceita pelo Zabbix 8.0 RC1. Se o server rejeitar a versão, o script avisa no final.
- O log fica em `/var/log/zabbix-install.log`, com permissão 600 e **sem a senha**.

## Solução de problemas

| Sintoma | O que verificar |
|---|---|
| O script parou com `ERRO na linha ...` | A linha e o comando que falharam aparecem na tela e no log |
| Frontend mostra código PHP em vez da página | `a2enconf php*-fpm`, `systemctl restart php*-fpm apache2` |
| Zabbix server não inicia | `journalctl -u zabbix-server` e `/var/log/zabbix/zabbix_server.log` |
| Repositório sem suporte para sua versão do Ubuntu | Use Ubuntu 24.04, ou aguarde o suporte do TimescaleDB/PGDG |
| Não encontrou o `.deb` do Zabbix | Informe a URL com `ZBX_RELEASE_URL` |

## Licença

[MIT](LICENSE). Use por sua conta e risco, o script é fornecido sem garantias.
