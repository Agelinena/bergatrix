# Bergastream — usuários

**Com o Authentik (padrão desde a 0.4):** as contas vêm do Authentik. Quem está no grupo
`bergastream_users` entra por "Entrar com o Authentik", e a conta do Bergastream é criada ou ligada
à que já existia no primeiro login. Configuração e migração das contas antigas:
[AUTHENTIK.md](AUTHENTIK.md). Para tirar o acesso de alguém, tire a pessoa do grupo no Authentik
e desative a conta no Bergastream (as sessões abertas não dependem do Authentik).

## Página "Usuários" (admin)

No app ou na web: **Ajustes → Conta → Usuários** (só aparece para admin).

| Ação | Observação |
|---|---|
| Novo usuário | Conta sem senha. Com e-mail, manda o convite: com senha ligada, um link para criar a senha (vale `INVITE_HOURS`); com o Authentik, como entrar. |
| Editar nome, usuário e e-mail | Bloqueado em conta já ligada ao Authentik (vem de lá). Em conta ainda não ligada, avisa que isso muda a ligação. Avisa a pessoa por e-mail (o e-mail antigo também). |
| Tornar/tirar admin | Bloqueado se o admin vem do grupo do Authentik (`OIDC_ADMIN_GROUP`). Sempre fica pelo menos um admin; ninguém tira o próprio admin. |
| Redefinir senha | Só com login por senha ligado e conta que não vem do Authentik. **Link por e-mail** (a pessoa cria a senha, vale `PASSWORD_RESET_HOURS`) ou **senha temporária** (aparece uma vez para você passar; o e-mail avisa sem mandar a senha). Os aparelhos desconectam. |
| Mandar aviso por e-mail | Mensagem livre (ex.: "troquei sua senha", "servidor em manutenção"). |
| Desconectar os aparelhos | Pedem login de novo em até 15 min. |
| Desligar do Authentik | Só se ligou na conta errada. |
| Desativar / reativar | A pessoa não entra (nem pelo Authentik) e os aparelhos desconectam; playlists e histórico ficam. Opção de avisar por e-mail. |
| Testar e-mail | Manda um e-mail para você (cadastre seu e-mail em Ajustes → Conta). |

Cada pessoa vê em **Ajustes → Conta** os próprios dados. Se a conta vem do Authentik, o botão
"Gerenciar no Authentik" abre a página de lá; senão, dá para editar o perfil e trocar a senha.
Com o Authentik ligado, quem ainda não entrou por lá só muda o próprio nome: usuário e e-mail ligam
as contas no 1º login, então só o admin troca (senão alguém poria o e-mail de outra pessoa). Na
tela de login, "Esqueci minha senha" manda o link por e-mail (com login por senha ligado e SMTP
configurado; a resposta é a mesma com ou sem conta, e há limite de pedidos por IP).

## E-mail (SMTP)

Variáveis `SMTP_*` e `APP_URL` no `.env` (ver `.env.example`); pode ser a mesma conta de SMTP do
Authentik. Sem SMTP, nada é enviado e o resto funciona igual. Os e-mails saem em texto e HTML
simples, em português, e terminam com "Se não foi você quem pediu isso, fale com o administrador".

**Sem o Authentik** (ou com `PASSWORD_LOGIN=true`): as contas com senha são criadas pela linha de
comando, dentro do container da API. O cadastro pelo app fica desligado
(`ALLOW_REGISTRATION=false` no `.env`); com `true`, o app mostra "Criar conta".

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

## Ligação com o Authentik

```bash
docker compose exec api python -m app.auth.cli list-users                       # [Authentik] = já ligada
docker compose exec api python -m app.auth.cli set-email <usuario> <email>      # liga pelo e-mail
docker compose exec api python -m app.auth.cli unlink-authentik <usuario>       # desfaz uma ligação errada
```

- `set-email`: quando o nome de usuário no Authentik é diferente do daqui, o 1º login liga as
  contas pelo e-mail (o mesmo cadastrado no Authentik).
- `unlink-authentik`: encerra as sessões e deixa a conta livre para ser ligada de novo no próximo
  login pelo Authentik.

## Login bloqueado

Depois de 5 senhas erradas em 15 minutos para o mesmo usuário e IP, o login responde
"Muitas tentativas" por 15 minutos. Basta esperar; trocar a senha não desbloqueia antes.

## Remover uma pessoa

Use **Desativar conta** na página Usuários: a pessoa não entra mais e os aparelhos desconectam,
mas playlists (inclusive as compartilhadas com outros) e histórico ficam. Apagar de vez ainda
não tem botão, de propósito.

## Dados pessoais (LGPD)

O banco guarda nome de usuário, hash da senha (Argon2), e-mail e identificador do Authentik
(quando entra por lá), data do último login e da desativação, playlists e histórico de reprodução
de cada pessoa. Os links de redefinir senha ficam só como hash e valem uma vez. O log da API
registra as ações do admin pelo id da conta, sem e-mail nem senha. Trate os backups (`pg_dump`) como dado pessoal: guarde em local protegido e não
compartilhe.
