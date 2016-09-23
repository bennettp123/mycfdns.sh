# mycfdns.sh
A dynamic dns updater for cloudflare, written in bash and python.

## Instructions:

 1. `mycfdns.sh --help`
 2. `mycfdns.sh -z <zone> -h <fqdn> -e <email> -k <apikey>`
 3. Use cron to schedule it to occurr at regular intervals.

## Known limitations:

* Does not support multiple records with the same name.
* IPv4 only (no IPv6 support).

License: MIT.<br />Warranty: None.

Enjoy!

