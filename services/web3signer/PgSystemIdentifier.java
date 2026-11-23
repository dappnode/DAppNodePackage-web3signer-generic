import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;

/**
 * Prints the system identifier of a Postgres database, which changes when its data directory is
 * recreated. Runs with the JDBC driver bundled with Web3Signer, so the image needs no Postgres client.
 *
 * <p>Usage: java -cp postgresql.jar:. PgSystemIdentifier JDBC_URL USER (password in PGPASSWORD)
 */
public class PgSystemIdentifier {
  public static void main(final String[] args) throws Exception {
    try (Connection connection =
            DriverManager.getConnection(args[0], args[1], System.getenv("PGPASSWORD"));
        ResultSet result =
            connection
                .createStatement()
                .executeQuery("SELECT system_identifier FROM pg_control_system()")) {
      result.next();
      System.out.println(result.getString(1));
    }
  }
}
