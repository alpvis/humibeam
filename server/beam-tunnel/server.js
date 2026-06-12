#!/usr/bin/env node
// Humibeam Beam-Tunnel — Rendezvous für MacBeam unterwegs (Mac hinter NAT).
//
// Mac und iPhone verbinden sich beide HIERHER; der Server verklebt nur die beiden
// Sockets. Der gesamte Verkehr ist Ende-zu-Ende AES-GCM-verschlüsselt (beamSecret
// aus dem QR-Pairing) — der Server sieht ausschließlich Chiffrat.
//
// Handshake: erste Zeile (JSON + \n): {"role":"mac"|"ios","channel":"<sha256(beamSecret) hex>"}
// Danach: rohe Beam-Pakete in beide Richtungen.
//
// config.json: { "port": 8797, "bindHost": "0.0.0.0" }
'use strict';

const net = require('net');
const fs = require('fs');
const path = require('path');

const config = JSON.parse(fs.readFileSync(path.join(__dirname, 'config.json'), 'utf8'));

// channel → wartende Mac-Standby-Verbindung
const waitingMacs = new Map();

const server = net.createServer((socket) => {
  socket.setNoDelay(true);
  let buffer = Buffer.alloc(0);
  let handshaken = false;

  const onData = (chunk) => {
    if (handshaken) return;
    buffer = Buffer.concat([buffer, chunk]);
    const nl = buffer.indexOf(10);
    if (nl < 0) {
      if (buffer.length > 4096) socket.destroy();
      return;
    }
    let head;
    try { head = JSON.parse(buffer.subarray(0, nl).toString('utf8')); }
    catch { return socket.destroy(); }
    const rest = buffer.subarray(nl + 1);
    const channel = String(head.channel || '');
    if (!/^[0-9a-f]{64}$/.test(channel)) return socket.destroy();
    handshaken = true;
    socket.removeListener('data', onData);

    if (head.role === 'mac') {
      // Alte Standby-Verbindung ersetzen.
      const old = waitingMacs.get(channel);
      if (old && old !== socket) old.destroy();
      waitingMacs.set(channel, socket);
      socket.on('close', () => {
        if (waitingMacs.get(channel) === socket) waitingMacs.delete(channel);
      });
      console.log(`mac wartet: ${channel.slice(0, 8)}… (${waitingMacs.size} Kanäle)`);
    } else if (head.role === 'ios') {
      const mac = waitingMacs.get(channel);
      if (!mac) {
        console.log(`ios ohne mac: ${channel.slice(0, 8)}…`);
        return socket.destroy();
      }
      waitingMacs.delete(channel);
      console.log(`verbunden: ${channel.slice(0, 8)}…`);
      // Sockets verkleben; evtl. schon mitgelesene Bytes weiterreichen.
      if (rest.length) mac.write(rest);
      socket.pipe(mac);
      mac.pipe(socket);
      const teardown = () => { socket.destroy(); mac.destroy(); };
      socket.on('close', teardown); socket.on('error', teardown);
      mac.on('close', teardown); mac.on('error', teardown);
    } else {
      socket.destroy();
    }
  };

  socket.on('data', onData);
  socket.on('error', () => {});
  // Wer 30 s lang keinen Handshake schafft, fliegt.
  setTimeout(() => { if (!handshaken) socket.destroy(); }, 30_000);
});

server.listen(config.port || 8797, config.bindHost || '0.0.0.0', () => {
  console.log(`beam-tunnel läuft auf ${config.bindHost || '0.0.0.0'}:${config.port || 8797}`);
});
