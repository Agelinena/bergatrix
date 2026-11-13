# Clona ou atualiza os repositórios listados em repos.txt (versão Windows do ./sync).
#   .\sync.ps1          clona o que falta e atualiza (só fast-forward) o que está limpo
#   .\sync.ps1 status   mostra branch, mudanças locais e commits a enviar/receber
# Repositório com mudança local ou fora do branch padrão não é tocado.
param([string]$Mode = 'sync')
Set-Location $PSScriptRoot

# SSH se o agente (Bitwarden) tiver chave; senão HTTPS (gh auth setup-git)
$ssh = 'C:/Windows/System32/OpenSSH/ssh.exe'
$sshOk = (& $ssh -o BatchMode=yes -T git@github.com 2>&1 | Out-String) -match 'successfully authenticated'

foreach ($line in Get-Content repos.txt) {
    if ($line -match '^\s*(#|$)') { continue }
    $dir, $repo = -split $line
    if (-not (Test-Path "$dir/.git")) {
        if ($Mode -eq 'status') { "${dir}: não clonado"; continue }
        "== ${dir}: clonando $repo"
        New-Item -ItemType Directory -Force (Split-Path $dir) | Out-Null
        if ($sshOk) { git -c core.sshCommand=$ssh clone "git@github.com:$repo.git" $dir; git -C $dir config core.sshCommand $ssh }
        else { git clone "https://github.com/$repo.git" $dir }
        continue
    }
    $branch = git -C $dir symbolic-ref --short -q HEAD
    if (-not $branch) { $branch = '(detached)' }
    git -C $dir fetch -q origin
    if ($LASTEXITCODE -ne 0) { "${dir}: falha no fetch"; continue }
    $dirty = @(git -C $dir status --porcelain).Count
    $counts = git -C $dir rev-list --left-right --count 'HEAD...@{u}' 2>$null
    if ($counts) { $ahead, $behind = -split $counts } else { $ahead = '?'; $behind = '?' }
    if ($Mode -eq 'status') { "${dir}: $branch, $dirty alterado(s), $ahead a enviar, $behind a receber"; continue }
    if ($dirty -ne 0 -or $behind -eq '0' -or $behind -eq '?') {
        "== ${dir}: $branch, $dirty alterado(s), $ahead a enviar, $behind a receber (sem pull)"
    } else {
        "== ${dir}: recebendo $behind commit(s)"
        git -C $dir merge --ff-only -q '@{u}'
        if ($LASTEXITCODE -ne 0) { '   não deu fast-forward; resolva à mão' }
    }
}
