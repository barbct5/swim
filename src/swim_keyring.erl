-module(swim_keyring).

-export([new/1]).
-export([new/2]).
-export([add/2]).
-export([encrypt/2]).
-export([decrypt/2]).

-define(AAD, crypto:hash(sha256, term_to_binary(erlang:get_cookie()))).

-record(keyring, {
          keys :: nonempty_list(<<_:256>>),
          aad  :: binary()
         }).

-opaque keyring() :: #keyring{}.
-export_type([keyring/0]).

new(Keys) ->
    new(Keys, ?AAD).

new(Keys, AAD)
  when is_list(Keys) andalso Keys =/= [] ->
    #keyring{keys = Keys, aad = AAD}.

add(Key, KeyRing)
  when is_binary(Key) andalso byte_size(Key) =:= 32 ->
    KeyRing#keyring{keys = [Key | KeyRing#keyring.keys]}.

%% @doc Encrypts the provided plain text using the Advanced Encryption Standard
%% (AES) in Galois/Counter (GCM) using the provided 32-octet Key,
%% Associated Authenticated Data (AAD), and a randomly generated
%% Initialization Vector (IV). The resulting payload includes the 16-octet IV,
%% the 16-octet CipherTag and the block encrypted cipher text.
%% @end
-spec encrypt(PlainText, Keyring) -> CipherText when
      PlainText  :: iodata(),
      Keyring    :: keyring(),
      CipherText :: iodata().

encrypt(PlainText, #keyring{keys = [Key | _], aad = AAD}) ->
    IV = crypto:strong_rand_bytes(16),
    {CipherText, CipherTag} = crypto:block_encrypt(aes_gcm, Key, IV, {AAD, PlainText}),
    <<IV/binary, CipherTag/binary, CipherText/binary>>.

%% @doc Verifies the authenticity of the payload and decrypts the ciphertext
%% generated by {@link encrypt/3}. Note the keys used as input to {@link encrypt/3}
%% must be identical to those provided here. Decrypt is not responsible for
%% decoding the underlying Swim protocol message -- see {@link decode/1}.
-spec decrypt(CipherText, KeyRing) -> {ok, PlainText} | {error, failed_verification} when
      CipherText :: binary(),
      KeyRing    :: keyring(),
      PlainText  :: binary().

decrypt(<<IV:16/binary, CipherTag:16/binary, CipherText/binary>>, Keyring) ->
    #keyring{keys = Keys, aad = AAD} = Keyring,
    decrypt_loop(Keys, AAD, IV, CipherTag, CipherText);
decrypt(_CipherText, _KeyRing) ->
    {error, failed_verification}.

decrypt_loop([], _AAD, _IV, _CipherTag, _CipherText) ->
    {error, failed_verification};
decrypt_loop([Key | Keys], AAD, IV, CipherTag, CipherText) ->
    case crypto:block_decrypt(aes_gcm, Key, IV, {AAD, CipherText, CipherTag}) of
        error ->
            decrypt_loop(Keys, AAD, IV, CipherTag, CipherText);
        PlainText ->
            {ok, PlainText}
    end.

