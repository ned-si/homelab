package snapshot

import (
	"crypto/ed25519"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"strings"
)

// SignatureHeader carries the Ed25519 signature of a pushed snapshot body.
const SignatureHeader = "Snapshot-Signature"

const signaturePrefix = "ed25519="

// Sign returns the SignatureHeader value for body.
func Sign(key ed25519.PrivateKey, body []byte) string {
	return signaturePrefix + base64.StdEncoding.EncodeToString(ed25519.Sign(key, body))
}

// Verify reports whether header is a valid signature of body by one of keys.
func Verify(keys []ed25519.PublicKey, header string, body []byte) bool {
	enc, ok := strings.CutPrefix(header, signaturePrefix)
	if !ok {
		return false
	}
	sig, err := base64.StdEncoding.DecodeString(enc)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return false
	}
	for _, k := range keys {
		if ed25519.Verify(k, body, sig) {
			return true
		}
	}
	return false
}

// ParsePrivateKey reads an Ed25519 private key from a PKCS #8 PEM block, as
// written by `openssl genpkey -algorithm ed25519`.
func ParsePrivateKey(data []byte) (ed25519.PrivateKey, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("no PEM block")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse PKCS #8: %w", err)
	}
	ek, ok := k.(ed25519.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("a %T, not an Ed25519 key", k)
	}
	return ek, nil
}

// ParsePublicKeys reads one or more Ed25519 public keys from PKIX PEM blocks,
// as written by `openssl pkey -pubout`. Two keys cover a rotation.
func ParsePublicKeys(data []byte) ([]ed25519.PublicKey, error) {
	var keys []ed25519.PublicKey
	for {
		var block *pem.Block
		block, data = pem.Decode(data)
		if block == nil {
			break
		}
		k, err := x509.ParsePKIXPublicKey(block.Bytes)
		if err != nil {
			return nil, fmt.Errorf("parse PKIX: %w", err)
		}
		ek, ok := k.(ed25519.PublicKey)
		if !ok {
			return nil, fmt.Errorf("a %T, not an Ed25519 key", k)
		}
		keys = append(keys, ek)
	}
	if len(keys) == 0 {
		return nil, errors.New("no PEM block")
	}
	return keys, nil
}
