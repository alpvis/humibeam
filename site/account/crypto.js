// Zero-Knowledge-Konto-Krypto im Browser — bit-genau zu HumibeamMac/Services/AccountSync/AccountCrypto.swift.
// PBKDF2-SHA256(passwort, kdfSalt, 600k) → master; authKey=HKDF(master,"humibeam-auth"),
// encKey=HKDF(master,"humibeam-enc"). Server sieht nie Passwort/Klartext.
export const PBKDF2_ROUNDS = 600000;

function hexToBytes(hex) {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
  return out;
}
function bytesToHex(buf) {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// HKDF-SHA256 mit leerem Salt (CryptoKit-Default bei deriveKey(inputKeyMaterial:info:)).
async function hkdf(masterBytes, infoStr, length = 32) {
  const key = await crypto.subtle.importKey('raw', masterBytes, 'HKDF', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(0), info: new TextEncoder().encode(infoStr) },
    key, length * 8);
  return new Uint8Array(bits);
}

export async function deriveKeys(password, kdfSaltHex) {
  const salt = hexToBytes(kdfSaltHex);
  const pwKey = await crypto.subtle.importKey('raw', new TextEncoder().encode(password),
    'PBKDF2', false, ['deriveBits']);
  const masterBits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', hash: 'SHA-256', salt, iterations: PBKDF2_ROUNDS }, pwKey, 256);
  const master = new Uint8Array(masterBits);
  const authKey = await hkdf(master, 'humibeam-auth');
  const encKey = await hkdf(master, 'humibeam-enc');
  return { authKeyHex: bytesToHex(authKey), encKey };
}

// AES-GCM "combined" (nonce(12)+ciphertext+tag(16)), Base64 — wie AES.GCM.SealedBox.combined.
export async function decryptBlob(base64, encKey) {
  const combined = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  const nonce = combined.slice(0, 12);
  const body = combined.slice(12);
  const key = await crypto.subtle.importKey('raw', encKey, 'AES-GCM', false, ['decrypt']);
  const plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: nonce }, key, body);
  return new TextDecoder().decode(plain);
}

// Gegenstück zu decryptBlob: AES-GCM "combined" (nonce(12)+ciphertext+tag(16)) → Base64.
export async function encryptBlob(plaintext, encKey) {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const key = await crypto.subtle.importKey('raw', encKey, 'AES-GCM', false, ['encrypt']);
  const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, key, new TextEncoder().encode(plaintext));
  const combined = new Uint8Array(nonce.length + ct.byteLength);
  combined.set(nonce, 0);
  combined.set(new Uint8Array(ct), nonce.length);
  let bin = '';
  for (let i = 0; i < combined.length; i += 0x8000) bin += String.fromCharCode.apply(null, combined.subarray(i, i + 0x8000));
  return btoa(bin);
}

export const randomSaltHex = () => bytesToHex(crypto.getRandomValues(new Uint8Array(16)));
