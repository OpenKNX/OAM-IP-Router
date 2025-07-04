### Tunnelverbindungen

Hier können bestimmte Tunnel (mit einer eindeutigen PA = physikalischen Adresse) Endgeräten exklusiv zugewiesen werden. Die Identifizierung erfolgt anhand der IP-Adresse des Endgeräts (Tunnel-Client).

Das Verhalten bei einem belegten, reservierten Tunnel kann gewählt werden: Entweder wird der Tunnel-Request abgelehnt, dem nächsten freien (nicht zugeordnetem) Tunnel zugewiesen oder die bestehende Tunnelverbindung wird getrennt und der belegte Tunnel genutzt.

Für einen reibungslosen Betrieb mit der ETS empfiehlt es sich für die ETS mindestens 2, besser 3 Tunnel nicht zuzuordnen.

Das Feature ist insbesondere sinnvoll für Visu- oder Logikserver, die per Tunnelverbindung angebunden sind und immer mit der selben PA kommunizieren sollen.