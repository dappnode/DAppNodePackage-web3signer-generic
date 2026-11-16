import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import javax.naming.ldap.LdapName;
import javax.naming.ldap.Rdn;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Set;

/** Remove compromised CA trust paths by public key, independently of alias names. */
public final class RemoveDistrustedRoots {
  private static final Set<String> BLOCKED = Set.of(
      "bd153ed7b0434f6886b17bce8bbe84ed340c7132d702a8f4fa318f756ecbd6f3",
      "c619e4780ed8e0abeda24ad732567de4383a7ea941338f6d1a7d1b49ac792fe9",
      "8d417db2dd8bf5e3084d1e3f196d583849d81bdd4c00c70b9d39369e96b8c782");

  // Oracle's current mitigation includes all four roots, including G1/G2.
  private static final Set<String> BLOCKED_COMMON_NAMES = Set.of(
      "emSign ECC Root CA - G3", "AAA Certificate Services",
      "emSign Root CA - G1", "emSign Root CA - G2");

  public static void main(String[] args) throws Exception {
    Path path = args.length == 0
        ? Path.of(System.getProperty("java.home"), "lib", "security", "cacerts")
        : Path.of(args[0]);
    char[] password = "changeit".toCharArray();
    KeyStore store = KeyStore.getInstance(path.toFile(), password);
    MessageDigest sha256 = MessageDigest.getInstance("SHA-256");
    ArrayList<String> removed = new ArrayList<>();
    for (String alias : Collections.list(store.aliases())) {
      Certificate certificate = store.getCertificate(alias);
      if (certificate == null) continue;
      byte[] digest = sha256.digest(certificate.getPublicKey().getEncoded());
      StringBuilder hex = new StringBuilder();
      for (byte b : digest) hex.append(String.format("%02x", b & 0xff));
      boolean blockedName = false;
      if (certificate instanceof X509Certificate) {
        X509Certificate x509 = (X509Certificate) certificate;
        for (Rdn rdn : new LdapName(x509.getSubjectX500Principal().getName()).getRdns()) {
          if ("CN".equalsIgnoreCase(rdn.getType()) && BLOCKED_COMMON_NAMES.contains(rdn.getValue().toString())) {
            blockedName = true;
          }
        }
      }
      if (BLOCKED.contains(hex.toString()) || blockedName) {
        store.deleteEntry(alias);
        removed.add(alias);
      }
    }
    if (store.size() < 80) throw new IllegalStateException("Unexpectedly small trust store");
    if (!removed.isEmpty()) {
      try (OutputStream output = Files.newOutputStream(path)) {
        store.store(output, password);
      }
    }
    System.out.println("Removed distrusted Java roots: " + removed.size());
  }
}
