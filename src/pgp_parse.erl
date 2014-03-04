-module(pgp_parse).
-export([decode_stream/2, decode_stream/1]).

-define(OLD_PACKET_FORMAT, 2).
-define(SIGNATURE_PACKET, 2).
-define(PUBKEY_PACKET, 6).
-define(UID_PACKET, 13).
-define(SUBKEY_PACKET, 14).
-define(PGP_VERSION, 4).

-define(PK_ALGO_RSA_ES, 1).
-define(PK_ALGO_RSA_E, 2).
-define(PK_ALGO_RSA_S, 3).
-define(PK_ALGO_ELGAMAL, 16).
-define(PK_ALGO_DSA, 17).

-define(HASH_ALGO_MD5, 1).
-define(HASH_ALGO_SHA1, 2).
-define(HASH_ALGO_RIPEMD160, 3).
-define(HASH_ALGO_SHA256, 8).
-define(HASH_ALGO_SHA384, 9).
-define(HASH_ALGO_SHA512, 10).
-define(HASH_ALGO_SHA224, 11).

-record(decoder_ctx, {primary_key, subkey, uid}).

decode_stream(Data) -> decode_stream(Data, []).
decode_stream(Data, Opts) ->
	Contents = case proplists:get_bool(file, Opts) of
		true -> {ok, D} = file:read_file(Data), D;
		false -> Data
	end,
	Decoded = case proplists:get_bool(armor, Opts) of
		true -> pgp_armor:decode(Contents);
		false -> Contents
	end,
	decode_packets(Decoded, #decoder_ctx{}).

decode_packets(<<?OLD_PACKET_FORMAT:2/integer-big, Tag:4/integer-big,
				LenBits:2/integer-big, Body/binary>>, Context) ->
	{PacketData, S2Rest} = case LenBits of
		0 -> <<Length, Object:Length/binary, SRest/binary>> = Body, {Object, SRest};
		1 -> <<Length:16/integer-big, Object:Length/binary, SRest/binary>> = Body, {Object, SRest};
		2 -> <<Length:32/integer-big, Object:Length/binary, SRest/binary>> = Body, {Object, SRest}
	end,
	NewContext = decode_packet(Tag, PacketData, Context),
	decode_packets(S2Rest, NewContext);
decode_packets(Data, _) ->
	io:format("~p\n", [mochihex:to_hex(Data)]).

decode_packet(?SIGNATURE_PACKET, <<?PGP_VERSION, SigType, PubKeyAlgo, HashAlgo,
								   HashedLen:16/integer-big, HashedData:HashedLen/binary,
								   UnhashedLen:16/integer-big, UnhashedData:UnhashedLen/binary,
								   HashLeft16:2/binary, Signature/binary>>, Context) ->
	CHA = pgp_to_crypto_hash_algo(HashAlgo),
	HashCtx = crypto:hash_init(CHA),
	FinalCtx = case SigType of
		%% 0x18: Subkey Binding Signature
		%% 0x19: Primary Key Binding Signature
		KeyBinding when KeyBinding =:= 16#18; KeyBinding =:= 16#19 ->
			{PK, _} = Context#decoder_ctx.primary_key,
			{SK, _} = Context#decoder_ctx.subkey,
			crypto:hash_update(crypto:hash_update(HashCtx, PK), SK);
		%% 0x10: Generic certification of a User ID and Public-Key packet.
		%% 0x11: Persona certification of a User ID and Public-Key packet.
		%% 0x12: Casual certification of a User ID and Public-Key packet.
		%% 0x13: Positive certification of a User ID and Public-Key packet.
		Cert when Cert >= 16#10, Cert =< 16#13 ->
			{PK, _} = Context#decoder_ctx.primary_key,
			UID = Context#decoder_ctx.uid,
			crypto:hash_update(crypto:hash_update(HashCtx, PK), UID);
		_ -> io:format("Unknown SigType ~p\n", [SigType]), HashCtx %% XXX
	end,
	FinalData = <<?PGP_VERSION, SigType, PubKeyAlgo, HashAlgo,
				  HashedLen:16/integer-big, HashedData/binary>>,
	Trailer = <<?PGP_VERSION, 16#FF, (byte_size(FinalData)):32/integer-big>>,
	Expected = crypto:hash_final(crypto:hash_update(crypto:hash_update(FinalCtx, FinalData), Trailer)),
	<<HashLeft16:2/binary, _/binary>> = Expected,
	ContextAfterHashed = decode_signed_subpackets(HashedData, Context),
	ContextAfterUnhashed = decode_signed_subpackets(UnhashedData, ContextAfterHashed),
	CS = case PubKeyAlgo of
		RSA when RSA =:= ?PK_ALGO_RSA_ES; RSA =:= ?PK_ALGO_RSA_S ->
			{S, <<>>} = read_mpi(Signature), S;
		_ -> unknown %% XXX
	end,
	case SigType of
		16#18 ->
			{_, {CPA, CryptoPK}} = Context#decoder_ctx.primary_key,
			true = crypto:verify(CPA, CHA, {digest, Expected}, CS, CryptoPK);
		_ -> unknown
	end,
	io:format("SIGNATURE: ~p\n", [{SigType, PubKeyAlgo, HashAlgo, HashedLen, UnhashedLen,
								   HashLeft16}]),
	ContextAfterUnhashed;
decode_packet(Tag, <<?PGP_VERSION, Timestamp:32/integer-big, Algorithm, KeyRest/binary>> = KeyData, Context)
  when Tag =:= ?PUBKEY_PACKET; Tag =:= ?SUBKEY_PACKET ->
	Key = decode_pubkey_algo(Algorithm, KeyRest),
	Subject = <<16#99, (byte_size(KeyData)):16/integer-big, KeyData/binary>>,
	io:format("PUBKEY: ~p\n", [{Timestamp, Key, mochihex:to_hex(key_id(Subject))}]),
	case Tag of
		?PUBKEY_PACKET -> Context#decoder_ctx{primary_key = {Subject, Key}};
		?SUBKEY_PACKET -> Context#decoder_ctx{subkey = {Subject, Key}}
	end;
decode_packet(?UID_PACKET, UID, Context) ->
	io:format("UID: ~p\n", [UID]),
	Context#decoder_ctx{uid = <<16#B4, (byte_size(UID)):32/integer-big, UID/binary>>}.

read_mpi(<<Length:16/integer-big, Rest/binary>>) ->
	ByteLen = (Length + 7) div 8,
	<<Data:ByteLen/binary, Trailer/binary>> = Rest,
	{Data, Trailer}.

key_id(Subject) -> crypto:hash(sha, Subject).

decode_signed_subpackets(<<>>, Context) -> Context;
decode_signed_subpackets(<<Length, Payload:Length/binary, Rest/binary>>, C) when Length < 192 ->
	NC = decode_signed_subpacket(Payload, C),
	decode_signed_subpackets(Rest, NC);
decode_signed_subpackets(<<LengthHigh, LengthLow, PayloadRest/binary>>, C) when LengthHigh < 255 ->
	Length = ((LengthHigh - 192) bsl 8) bor LengthLow,
	<<Payload:Length/binary, Rest/binary>> = PayloadRest,
	NC = decode_signed_subpacket(Payload, C),
	decode_signed_subpackets(Rest, NC);
decode_signed_subpackets(<<255, Length:32/integer-big, Payload:Length/binary, Rest/binary>>, C) ->
	NC = decode_signed_subpacket(Payload, C),
	decode_signed_subpackets(Rest, NC).

%% 2 = Signature Creation Time
decode_signed_subpacket(<<2, Timestamp:32/integer-big>>, C) ->
	io:format("Signature Creation Time: ~p\n", [Timestamp]), C;
%% 9 = Key Expiration Time
decode_signed_subpacket(<<9, Timestamp:32/integer-big>>, C) ->
	io:format("Key Expiration Time: ~p\n", [Timestamp]), C;
%% 11 = Preferred Symmetric Algorithms
decode_signed_subpacket(<<11, Algorithms/binary>>, C) ->
	io:format("Preferred Symmetric Algorithms: ~p\n", [Algorithms]), C;
%% 16 = Issuer
decode_signed_subpacket(<<16, Issuer:8/binary>>, C) ->
	io:format("Issuer: ~p\n", [mochihex:to_hex(Issuer)]), C;
%% 21 = Preferred Hash Algorithms
decode_signed_subpacket(<<21, Algorithms/binary>>, C) ->
	io:format("Preferred Hash Algorithms: ~p\n", [Algorithms]), C;
%% 22 = Preferred Compression Algorithms
decode_signed_subpacket(<<22, Algorithms/binary>>, C) ->
	io:format("Preferred Compression Algorithms: ~p\n", [Algorithms]), C;
%% 23 = Key Server Preferences
decode_signed_subpacket(<<23, NoModify:1/integer, _/bits>>, C) ->
	io:format("Key Server Preferences: ~p\n", [{NoModify}]), C;
%% 27 = Key Flags
decode_signed_subpacket(<<27, SharedPrivKey:1/integer, _:2/integer, SplitPrivKey:1/integer,
						  CanEncryptStorage:1/integer, CanEncryptComms:1/integer,
						  CanSign:1/integer, CanCertify:1/integer, _/binary>>, C) ->
	io:format("Key Flags: ~p\n", [{SharedPrivKey, SplitPrivKey, CanEncryptStorage,
								   CanEncryptComms, CanSign, CanCertify}]), C;
%% 30 = Features
decode_signed_subpacket(<<30, _:7/integer, ModificationDetection:1/integer, _/binary>>, C) ->
	io:format("Features: ~p\n", [{ModificationDetection}]), C;
decode_signed_subpacket(<<Tag, _/binary>>, C) -> io:format("Ingored ~p\n", [Tag]), C.

pgp_to_crypto_hash_algo(?HASH_ALGO_MD5) -> md5;
pgp_to_crypto_hash_algo(?HASH_ALGO_SHA1) -> sha;
pgp_to_crypto_hash_algo(?HASH_ALGO_RIPEMD160) -> ripemd160;
pgp_to_crypto_hash_algo(?HASH_ALGO_SHA256) -> sha256;
pgp_to_crypto_hash_algo(?HASH_ALGO_SHA384) -> sha384;
pgp_to_crypto_hash_algo(?HASH_ALGO_SHA512) -> sha512;
pgp_to_crypto_hash_algo(?HASH_ALGO_SHA224) -> sha224.

decode_pubkey_algo(RSA, Data)
  when RSA =:= ?PK_ALGO_RSA_ES; RSA =:= ?PK_ALGO_RSA_E; RSA =:= ?PK_ALGO_RSA_S ->
	{N, Rest} = read_mpi(Data),
	{E, <<>>} = read_mpi(Rest),
	{rsa, [E, N]}.
