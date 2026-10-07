# Bergastream — usuários

Contas são criadas pela linha de comando, dentro do container da API. O cadastro pelo app fica
desligado (`ALLOW_REGISTRATION=false` no `.env`); com `true`, o app mostra "Criar conta".

Rode na pasta `03-apps/bergastream` do servidor.

## Criar

```bash
docker compose exec api python -m app.auth.cli create-user <usuario>           # comum
docker compose exec api python -m app.auth.cli create-user <usuario> --admin   # administrador
```

- A senha é pedida duas vezes no terminal (não aparece na tela nem fica no histórico do shell).
- Mínimo de 8 caracteres.
- O nome de usuário é o login no app e na web, e o que aparece em "adicionado por" nas playlists.
- **Administrador** pode, além do normal, rodar a limpeza de arquivos (`POST /api/admin/cleanup`).

Usuários iniciais:

```bash
docker compose exec api python -m app.auth.cli create-user lucas --admin
docker compose exec api python -m app.auth.cli create-user marina
```

## Listar

```bash
docker compose exec api python -m app.auth.cli list-users
```

## Trocar senha

```bash
docker compose exec api python -m app.auth.cli set-password <usuario>
```

Encerra todas as sessões abertas da pessoa: os apps pedem login de novo (as músicas baixadas
continuam no aparelho).

## Criar sem terminal interativo (script)

```bash
printf '%s\n' 'senha-da-pessoa' | docker compose exec -T api \
  python -m app.auth.cli create-user <usuario> --password-stdin
```

Evite deixar a senha no histórico do shell: prefira o modo interativo.

## Login bloqueado

Depois de 5 senhas erradas em 15 minutos para o mesmo usuário e IP, o login responde
"Muitas tentativas" por 15 minutos. Basta esperar; trocar a senha não desbloqueia antes.

## Remover uma pessoa

Ainda não há comando. Para impedir o acesso, troque a senha por uma aleatória (as sessões caem
na hora):

```bash
openssl rand -base64 24 | docker compose exec -T api \
  python -m app.auth.cli set-password <usuario> --password-stdin
```

## Dados pessoais (LGPD)

O banco guarda nome de usuário, hash da senha (Argon2), playlists e histórico de reprodução de
cada pessoa. Trate os backups (`pg_dump`) como dado pessoal: guarde em local protegido e não
compartilhe.
