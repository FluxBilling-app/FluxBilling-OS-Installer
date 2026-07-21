/*
 * Copyright (C) 2026 FluxBilling.app
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 2 of the
 * License, or any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
 * 02110-1301, USA.
 *
 * You can also choose to distribute this program under the terms of
 * the Unmodified Binary Distribution Licence (as given in the file
 * COPYING.UBDL), provided that you have satisfied its requirements.
 *
 * No FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL ) declaration here on purpose:
 * builder.Dockerfile appends this file to the END of iPXE's
 * hci/commands/image_cmd.c, which already carries that declaration. The
 * macro expands to a PROVIDE_SYMBOL, so a second one in the same
 * translation unit is a duplicate definition. The licence terms above
 * match image_cmd.c's, so the linked object's declaration stays correct.
 */

/* FluxBilling: parse "a.b.c.d/nn" into fluxip / fluxmask / fluxprefix / fluxgw.
 * Appended to an always-linked iPXE command file by build.sh.
 *
 *   fluxcidr 203.0.113.111/27
 *     -> fluxip=203.0.113.111 fluxmask=255.255.255.224 fluxprefix=27
 *        fluxgw=203.0.113.97   (first usable host; for /31 the partner
 *                              address; skips the IP itself)
 *
 * Returns error (script can || catch) on missing slash, bad prefix (1-31)
 * or malformed IP.
 */
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <byteswap.h>
#include <ipxe/command.h>
#include <ipxe/in.h>

static int fluxcidr_exec ( int argc, char **argv ) {
	char ipbuf[16];
	char cmd[64];
	struct in_addr parsed;
	const char *combo;
	char *slash;
	char *end;
	unsigned long prefix;
	unsigned long mask;
	unsigned long ipa;
	unsigned long gw;
	size_t iplen;

	if ( argc != 2 ) {
		printf ( "Usage: fluxcidr <ip/prefix>\n" );
		return -EINVAL;
	}
	combo = argv[1];
	slash = strchr ( combo, '/' );
	if ( ! slash )
		return -EINVAL;
	iplen = ( slash - combo );
	if ( ( iplen < 7 ) || ( iplen >= sizeof ( ipbuf ) ) )
		return -EINVAL;
	prefix = strtoul ( ( slash + 1 ), &end, 10 );
	if ( *end || ( prefix < 1 ) || ( prefix > 31 ) )
		return -EINVAL;
	memcpy ( ipbuf, combo, iplen );
	ipbuf[iplen] = '\0';
	if ( inet_aton ( ipbuf, &parsed ) == 0 )
		return -EINVAL;
	ipa = ntohl ( parsed.s_addr );

	mask = ( 0xffffffffUL << ( 32 - prefix ) ) & 0xffffffffUL;
	if ( prefix == 31 ) {
		gw = ( ipa ^ 1 );
	} else {
		gw = ( ( ipa & mask ) + 1 );
		if ( gw == ipa )
			gw = ( ( ipa & mask ) + 2 );
	}
	snprintf ( cmd, sizeof ( cmd ), "set fluxip %s", ipbuf );
	system ( cmd );
	snprintf ( cmd, sizeof ( cmd ), "set fluxmask %ld.%ld.%ld.%ld",
		   ( ( mask >> 24 ) & 0xff ), ( ( mask >> 16 ) & 0xff ),
		   ( ( mask >> 8 ) & 0xff ), ( mask & 0xff ) );
	system ( cmd );
	snprintf ( cmd, sizeof ( cmd ), "set fluxprefix %ld", prefix );
	system ( cmd );
	snprintf ( cmd, sizeof ( cmd ), "set fluxgw %ld.%ld.%ld.%ld",
		   ( ( gw >> 24 ) & 0xff ), ( ( gw >> 16 ) & 0xff ),
		   ( ( gw >> 8 ) & 0xff ), ( gw & 0xff ) );
	system ( cmd );
	return 0;
}

COMMAND ( fluxcidr, fluxcidr_exec );
