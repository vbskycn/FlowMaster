package updater

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"strings"
	"testing"
)

func TestCompareSemverAndHashParsing(t *testing.T) {
	if CompareSemver("2.0.0", "2.1.0") != -1 {
		t.Fatalf("expected 2.0.0 < 2.1.0")
	}
	if CompareSemver("v2.1.0", "2.1.0") != 0 {
		t.Fatalf("expected v2.1.0 == 2.1.0")
	}
	if CompareSemver("2.10.0", "2.2.0") != 1 {
		t.Fatalf("expected 2.10.0 > 2.2.0")
	}

	hash := strings.Repeat("a", 64)
	sums := hash + "  flowmaster-linux-amd64.tar.gz\n" + strings.Repeat("b", 64) + " *flowmaster-linux-arm64.tar.gz\n"
	if got := parseExpectedHash(sums, "flowmaster-linux-amd64.tar.gz"); got != hash {
		t.Fatalf("unexpected hash: %s", got)
	}
	if got := parseExpectedHash(sums, "flowmaster-linux-arm64.tar.gz"); got != strings.Repeat("b", 64) {
		t.Fatalf("unexpected asterisk hash: %s", got)
	}
}

func TestExtractBinaryFromTarGz(t *testing.T) {
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	payload := []byte("mock-elf-binary")
	if err := tw.WriteHeader(&tar.Header{
		Name:     "flowmaster",
		Mode:     0o755,
		Size:     int64(len(payload)),
		Typeflag: tar.TypeReg,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := tw.Write(payload); err != nil {
		t.Fatal(err)
	}
	_ = tw.Close()
	_ = gz.Close()

	extracted, err := extractBinaryFromTarGz(buf.Bytes())
	if err != nil {
		t.Fatalf("extractBinaryFromTarGz failed: %v", err)
	}
	if !bytes.Equal(extracted, payload) {
		t.Fatalf("extracted payload mismatch")
	}
}
