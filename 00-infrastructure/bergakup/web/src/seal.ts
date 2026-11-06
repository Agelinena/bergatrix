// Segredos são cifrados aqui, no navegador, com a chave pública do agente
// (sealed box do libsodium: X25519 + XSalsa20-Poly1305). O servidor só vê o
// texto cifrado, e só o agente abre (agent/seal.go).
//
// Formato: chave pública efêmera (32) || crypto_box(msg, nonce, pk, esk),
// nonce = BLAKE2b-24(epk || pk).
import nacl from "tweetnacl";
import { blake2b } from "blakejs";

function fromB64(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function toB64(bytes: Uint8Array): string {
  let bin = "";
  bytes.forEach((b) => (bin += String.fromCharCode(b)));
  return btoa(bin);
}

export function seal(message: string, agentPublicKey: string): string {
  const pk = fromB64(agentPublicKey);
  if (pk.length !== 32) throw new Error("Chave pública do agente inválida.");
  const eph = nacl.box.keyPair();
  const nonceInput = new Uint8Array(64);
  nonceInput.set(eph.publicKey, 0);
  nonceInput.set(pk, 32);
  const nonce = blake2b(nonceInput, undefined, 24);
  const cipher = nacl.box(new TextEncoder().encode(message), nonce, pk, eph.secretKey);
  const out = new Uint8Array(32 + cipher.length);
  out.set(eph.publicKey, 0);
  out.set(cipher, 32);
  eph.secretKey.fill(0);
  return toB64(out);
}

// Senha aleatória legível: 8 grupos de 5 caracteres (~200 bits), sem 0/O/1/l.
export function randomPassword(): string {
  const alphabet = "abcdefghijkmnpqrstuvwxyz23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
  const bytes = new Uint8Array(40);
  crypto.getRandomValues(bytes);
  const chars = Array.from(bytes, (b) => alphabet[b % alphabet.length]);
  const groups: string[] = [];
  for (let i = 0; i < 40; i += 5) groups.push(chars.slice(i, i + 5).join(""));
  return groups.join("-");
}
