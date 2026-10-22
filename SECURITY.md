# Security reporting and scope

This app can control the local CRD sharing indicator through Accessibility. Target identification, permission boundaries, original-window restoration, and the explicit Stop Sharing action are security-relevant behavior.

Report sensitive problems through the repository's private vulnerability reporting feature when it is enabled. If no private reporting channel is available, open an issue asking the maintainer for a private contact method without including exploit details, credentials or personal data. No response-time commitment is made for this early source release.

Include the source revision, macOS/CRD version, whether the result is a fixture or live session, a minimal reproduction, and the observed boundary violation. Redact account names, PINs, tokens, host configuration and private paths. Do not attach a full support directory or screen recording of another person's session.

The project does not audit or replace Google's remote transport, authentication or broker. A build passing the automated tests is not a security certification. See [architecture](docs/ARCHITECTURE.md) and [privacy](docs/PRIVACY.md) for the implemented scope.

## Responsible use

Use this app only on Macs you own or administer, with the knowledge and consent of the people who use them. Follow local law. It changes only the local Chrome Remote Desktop notice window; it does not hide the session, the connection, or Google's own controls. The helper keeps its own menu bar item. To bring the original notice back, choose Original Sharing Window under Display Mode, or use Turn Off Window Helper.
