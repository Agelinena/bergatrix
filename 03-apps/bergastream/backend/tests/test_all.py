"""Testes automatizados da Etapa 2 — Bergastream."""
from __future__ import annotations
import asyncio, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))
from app.core.db import create_pool, close_pool
from app.core.redis import get_redis, close_redis
from app.tracks import repository as track_repo
from app.tracks.models import PlayRequest
from app.tracks import service as ts
from app.playlists.repository import add_track_to_playlist as atp, remove_track_from_playlist as rtp, get_track_playlist_count as gpc
from app.downloads.youtube import score_candidate as sc
P=0;F=0
def ok(a,b,m=''):global P,F;(P:=P+1,print(f'  OK {m}'))if a==b else(F:=F+1,print(f'  FAIL {m}: {a}!={b}'))
def okv(v,m=''):global P,F;(P:=P+1,print(f'  OK {m}'))if v else(F:=F+1,print(f'  FAIL {m}'))

async def t1(p):
    print('\n=== 1. Deducacao Cruzada ===')
    r1=await ts.resolve_and_register(p,PlayRequest(provider='spotify',external_id='S1',title='T',artist='A',album='Al',duration_seconds=200,isrc='I1'))
    tid=r1.track_id
    await p.execute("INSERT INTO files(track_id,path,size_bytes,format,kind)VALUES($1,$2,999,'mp3_192','cache')",tid,f'/cache/{tid}.mp3')
    r2=await ts.resolve_and_register(p,PlayRequest(provider='youtube',external_id='Y1',title='T',artist='A',duration_seconds=198))
    ok(r2.track_id,tid,'fuzzy match');ok(r2.status,'ready','ready')
    okv(await track_repo.get_track_by_external_id(p,'youtube','Y1'),'vinculado')
    await p.execute('DELETE FROM playlist_tracks WHERE track_id=$1',tid)
    await p.execute('DELETE FROM files WHERE track_id=$1',tid)
    await p.execute('DELETE FROM external_ids WHERE track_id=$1',tid)
    await p.execute('DELETE FROM tracks WHERE id=$1',tid)

async def t2(p):
    print('\n=== 2. Permanencia ===')
    r=await ts.resolve_and_register(p,PlayRequest(provider='youtube',external_id='PT',title='P',artist='P',duration_seconds=180))
    tid=r.track_id
    await p.execute("INSERT INTO files(track_id,path,size_bytes,format,kind)VALUES($1,$2,500,'mp3_192','cache')",tid,f'/cache/{tid}.mp3')
    ok(await p.fetchval('SELECT kind FROM files WHERE track_id=$1',tid),'cache','inicia cache')
    pa=await p.fetchval("SELECT p.id FROM playlists p JOIN users u ON u.id=p.user_id WHERE u.name='User A'")
    pb=await p.fetchval("SELECT p.id FROM playlists p JOIN users u ON u.id=p.user_id WHERE u.name='User B'")
    await atp(p,pa,tid);ok(await p.fetchval('SELECT kind FROM files WHERE track_id=$1',tid),'permanent','add A')
    await atp(p,pb,tid);ok(await p.fetchval('SELECT kind FROM files WHERE track_id=$1',tid),'permanent','add B')
    await rtp(p,pa,tid);ok(await p.fetchval('SELECT kind FROM files WHERE track_id=$1',tid),'permanent','remove A')
    ok(await gpc(p,tid),1,'1 restante')
    await rtp(p,pb,tid)
    ok(await p.fetchval('SELECT kind FROM files WHERE track_id=$1',tid),'cache','vira cache')
    okv(await p.fetchval('SELECT last_played_at FROM files WHERE track_id=$1',tid),'last_played_at')
    ok(await gpc(p,tid),0,'0 playlists')
    await atp(p,pa,tid);ok(await p.fetchval('SELECT kind FROM files WHERE track_id=$1',tid),'permanent','re-add')
    await p.execute('DELETE FROM files WHERE track_id=$1',tid)
    await p.execute('DELETE FROM playlist_tracks WHERE track_id=$1',tid)
    await p.execute('DELETE FROM external_ids WHERE track_id=$1',tid)
    await p.execute('DELETE FROM tracks WHERE id=$1',tid)

async def t3():
    print('\n=== 3. Concorrencia ===')
    r=await get_redis()
    for k in['bergastream:tq:high','bergastream:tq:low']:await r.delete(k)
    for i in range(3):await r.lpush('bergastream:tq:low',f'l{i}')
    await r.lpush('bergastream:tq:high','h1')
    ok(await r.llen('bergastream:tq:high'),1,'1 job high')
    ok(await r.llen('bergastream:tq:low'),3,'3 jobs low')
    j=await r.brpop(['bergastream:tq:high','bergastream:tq:low'],1);j=j[1] if j else None
    okv(j and j=='h1',f'high primeiro ({j})')
    for k in['bergastream:tq:high','bergastream:tq:low']:await r.delete(k)

def t4():
    print('\n=== 4. Scoring ===')
    ref=('Bohemian Rhapsody','Queen',355)
    okv(sc('Bohemian Rhapsody','Queen',355,*ref)>80,'ideal >80')
    ok(sc('Bohemian Rhapsody (Live Aid)','Queen',410,*ref),-1.0,'live fora tol -> -1')
    s=sc('Bohemian Rhapsody (Live)','Queen',355,*ref);okv(s<80,f'live <80 ({s:.0f})')
    okv(sc('Bohemian Rhapsody (Cover)','Cover Band',355,*ref)<80,'cover <80')
    okv(sc('Bohemian Rhapsody (Karaoke)','Karaoke',355,*ref)<80,'karaoke <80')
    ok(sc('Bohemian Rhapsody','Queen',200,*ref),-1.0,'duracao diff -> -1')

async def main():
    print('='*50+'\nTestes — Bergastream Etapa 2\n'+'='*50)
    p=await create_pool()
    await t1(p);await t2(p);await t3();t4()
    await p.execute('SELECT 1')
    await close_pool();await close_redis()
    global P,F
    print(f'\n{P} passaram, {F} falharam de {P+F}')
    print('TODOS OK!'if F==0 else'FALHAS!')
    return F

if __name__=='__main__':sys.exit(asyncio.run(main()))