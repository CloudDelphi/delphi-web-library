unit DWL.Crypt;

interface

uses
  System.SysUtils;

type
  TdwlCrypt = record
    class function TryMD5(const Bytes: TBytes; out Hash: TBytes): boolean; overload; static;
    class function TryMD5(const S: string; out Hash: TBytes): boolean; overload; static;
    class function MD5(const S: string): string; static;

    class function AsymmetricEncryption_GenerateKeyPair(var PrivateKey, PublicKey: TBytes): boolean; static;
    class function AsymmetricEncryption_Encrypt(var Bytes: TBytes; const PublicKey: TBytes): boolean; static;
    class function AsymmetricEncryption_Decrypt(var Bytes: TBytes; const PrivateKey: TBytes): boolean; static;

    class function AsymmetricSigning_GenerateKeyPair(var PrivateKey, PublicKey: TBytes): boolean; static;
    class function AsymmetricSigning_HashAndSign(const Bytes, PrivateKey: TBytes; out Signature: TBytes): boolean; static;
    class function AsymmetricSigning_CheckSignature(const Bytes, PublicKey, Signature: TBytes): boolean; static;

    class function AES_PrepareKey(BareKey:TBytes; var PreparedKey: TBytes): boolean; static;
    class function AES_PrepareKeyFromHexStr(const HexStr: string; var Key: TBytes): boolean; static;
    class function AES_Decrypt(var Bytes: TBytes; const Key: TBytes): boolean; overload; static;
    class function AES_Decrypt(var S: string; const Key: TBytes): boolean; overload; static;
    class function AES_Encrypt(var Bytes: TBytes; const Key: TBytes): boolean; overload; static;
    class function AES_Encrypt(var S: string; const Key: TBytes): boolean; overload; static;
  end;

implementation

uses
  DWL.SysUtils, DWL.Crypt.API, Winapi.Windows, System.Classes;

{ TdwlCrypt }

class function TdwlCrypt.MD5(const S: string): string;
begin
  var Hash: TBytes;
  if TryMD5(S, Hash) then
    Result := BytesToLowerHex(Hash)
  else
    Result := '';
end;

class function TdwlCrypt.TryMD5(const S: string; out Hash: TBytes): boolean;
begin
  Result := TryMD5(TEncoding.UTF8.GetBytes(S), Hash);
end;

class function TdwlCrypt.TryMD5(const Bytes: TBytes; out Hash: TBytes): boolean;
var
  hProv: HCRYPTPROV;
  hHash: HCRYPTHASH;
  dwDataLen: LongWord;
begin
  dwDataLen := 16;
  SetLength(Hash, dwDataLen);
  Result := false;
  if CryptAcquireContext(@hProv, nil, nil, PROV_RSA_AES, CRYPT_VERIFYCONTEXT) then
  try
    if CryptCreateHash(hProv, CALG_MD5, 0, 0, @hHash) then
    try
      if CryptHashData(hHash, @Bytes[0], length(Bytes), 0) then
      begin
        Result := CryptGetHashParam(hHash, HP_HASHVAL, @Hash[0], @dwDataLen, 0);
        Assert(dwDataLen=16);
      end;
    finally
      CryptDestroyHash(hHash);
    end;
  finally
    CryptReleaseContext(hProv, 0);
  end;
end;

class function TdwlCrypt.AES_PrepareKey(BareKey:TBytes; var PreparedKey: TBytes): boolean;
var
  KeyBufSize: word;
begin
  Result := false;
  try
    KeyBufSize := length(BareKey);
    if not ((KeyBufSize=16) or (KeyBufSize=24) or (KeyBufSize=32)) then
      raise Exception.Create('KeySize is not 16, 24 or 32');
    SetLength(PreparedKey, KeyBufSize+12);
    with PPUBLICKEYSTRUC(@PreparedKey[0])^ do
    begin
      bType := PLAINTEXTKEYBLOB;
      bVersion := CUR_BLOB_VERSION;
      reserved := 0;
      case KeyBufSize of
      16 : aiKeyAlg := CALG_AES_128;
      24 : aiKeyAlg := CALG_AES_192;
      32 : aiKeyAlg := CALG_AES_256;
      end;
    end;
    PDWORD(PByte(@PreparedKey[0])+8)^ := KeyBufSize;
    Move(BareKey[0], PreparedKey[12], KeyBufSize);
    Result := true;
  except
  end;
end;

class function TdwlCrypt.AES_PrepareKeyFromHexStr(const HexStr: string; var Key: TBytes): boolean;
var
  KeyBufSize: word;
begin
  Result := false;
  try
    KeyBufSize := Length(HexStr) div 2;
    if not ((KeyBufSize=16) or (KeyBufSize=24) or (KeyBufSize=32)) then
      raise Exception.Create('KeySize is not 16, 24 or 32');
    SetLength(Key, KeyBufSize+12);
    with PPUBLICKEYSTRUC(@Key[0])^ do
    begin
      bType := PLAINTEXTKEYBLOB;
      bVersion := CUR_BLOB_VERSION;
      reserved := 0;
      case KeyBufSize of
      16 : aiKeyAlg := CALG_AES_128;
      24 : aiKeyAlg := CALG_AES_192;
      32 : aiKeyAlg := CALG_AES_256;
      end;
    end;
    PDWORD(PByte(@Key[0])+8)^ := KeyBufSize;
    if HexToBin(PChar(HexStr), @Key[12], KeyBufSize)=KeyBufSize then
      Result := true;
  except
  end;
end;

class function TdwlCrypt.AsymmetricEncryption_Decrypt(var Bytes: TBytes; const PrivateKey: TBytes): boolean;
begin
  Result := false;
  try
    var hProv: HCRYPTPROV;
    if CryptAcquireContext(@hProv, nil, nil, PROV_RSA_AES, CRYPT_VERIFYCONTEXT) then
    try
      //import public key
      var hKey: HCRYPTKEY;
      if not CryptImportKey(hProv, @PrivateKey[0], Length(PrivateKey), 0, 0, @hKey) then
        Exit;
      try
        var DataSize := length(Bytes);
        if not CryptDecrypt(hKey, 0, true, 0, @Bytes[0], @DataSize) then
          Exit;
        SetLength(Bytes, DataSize);
        Result := true;
      finally
        CryptDestroyKey(hKey);
      end;
    finally
      CryptReleaseContext(hProv, 0);
    end;
  except
  end;
end;

class function TdwlCrypt.AsymmetricEncryption_Encrypt(var Bytes: TBytes; const PublicKey: TBytes): boolean;
begin
  Result := false;
  try
    var hProv: HCRYPTPROV;
    if not CryptAcquireContext(@hProv, nil, nil, PROV_RSA_AES, CRYPT_VERIFYCONTEXT) then
      Exit;
    try
      //import public key
      var hKey: HCRYPTKEY;
      if not CryptImportKey(hProv, @PublicKey[0], length(PublicKey), 0, 0, @hKey) then
          Exit;
      try
        var DataSize := length(Bytes);
        var BufSize := 1024+DataSize*2;  // rough estimate
        SetLength(Bytes, BufSize);
        if not CryptEncrypt(hKey, 0, true, 0, @Bytes[0], @DataSize, BufSize) then
          Exit;
        SetLength(Bytes, DataSize);
        Result := true;
      finally
        CryptDestroyKey(hKey);
      end;
    finally
      CryptReleaseContext(hProv, 0);
    end;
  except
  end;
end;

class function TdwlCrypt.AsymmetricEncryption_GenerateKeyPair(var PrivateKey, PublicKey: TBytes): boolean;
begin
  Result := false;
  try
    var hProv: HCRYPTPROV;
    if not CryptAcquireContext(@hProv, nil, nil, PROV_RSA_AES, CRYPT_VERIFYCONTEXT) then
      Exit;
    try
      var hKey: HCRYPTKEY;
      if not CryptGenKey(hProv, AT_KEYEXCHANGE, RSA1024BIT_KEY+CRYPT_EXPORTABLE, @hKey) then
        Exit;
      try
        // export Private Key
        var BufSize: DWORD;
        if not CryptExportKey(hKey, 0, PRIVATEKEYBLOB, 0, nil, @BufSize) then // get size of buf
          Exit;
        SetLength(PrivateKey, BufSize);
        if not CryptExportKey(hKey, 0, PRIVATEKEYBLOB, 0, @PrivateKey[0], @BufSize) then
          Exit;
        // export Public Key
        if not CryptExportKey(hKey, 0, PUBLICKEYBLOB, 0, nil, @BufSize) then // get size of buf
          Exit;
        SetLength(PublicKey, BufSize);
        if not CryptExportKey(hKey, 0, PUBLICKEYBLOB, 0, @PublicKey[0], @BufSize) then
          Exit;
        Result := true;
      finally
        CryptDestroyKey(hKey);
      end;
    finally
      CryptReleaseContext(hProv, 0);
    end;
  except
  end;
end;

class function TdwlCrypt.AsymmetricSigning_CheckSignature(const Bytes, PublicKey, Signature: TBytes): boolean;
begin
  Result := false;
  try
    var hProv: HCRYPTPROV;
    if not CryptAcquireContext(@hProv, nil, nil, PROV_RSA_AES, CRYPT_VERIFYCONTEXT) then
      Exit;
    try
      //import private key
      var  hKey: HCRYPTKEY;
      if not CryptImportKey(hProv, @PublicKey[0], length(PublicKey), 0, 0, @hKey) then
        Exit;
      try
        var hHash: HCRYPTHASH;
        if not CryptCreateHash(hProv, CALG_MD5, 0, 0, @hHash) then
          Exit;
        try
          if not CryptHashData(hHash, @Bytes[0], length(Bytes), 0) then
            Exit;
          Result := CryptVerifySignature(hHash, @Signature[0], Length(Signature), hKey, nil, 0);
        finally
          CryptDestroyHash(hHash);
        end;
      finally
        CryptDestroyKey(hKey);
      end;
    finally
      CryptReleaseContext(hProv, 0);
    end;
  except
  end;
end;

class function TdwlCrypt.AsymmetricSigning_GenerateKeyPair(var PrivateKey, PublicKey: TBytes): boolean;
begin
  Result := false;
  try
    var hProv: HCRYPTPROV;
    if not CryptAcquireContext(@hProv, nil, nil, PROV_RSA_AES, CRYPT_VERIFYCONTEXT) then
      Exit;
    try
      var  hKey: HCRYPTKEY;
      if not CryptGenKey(hProv, AT_KEYEXCHANGE, RSA1024BIT_KEY+CRYPT_EXPORTABLE, @hKey) then
        Exit;
      try
        // export Private Key
        var BufSize: DWORD;
        if not CryptExportKey(hKey, 0, PRIVATEKEYBLOB, 0, nil, @BufSize) then // get size of buf
          Exit;
        SetLength(PrivateKey, BufSize);
        if not CryptExportKey(hKey, 0, PRIVATEKEYBLOB, 0, @PrivateKey[0], @BufSize) then
          Exit;
        // export Public Key
        if not CryptExportKey(hKey, 0, PUBLICKEYBLOB, 0, nil, @BufSize) then // get size of buf
          Exit;
        SetLength(PublicKey, BufSize);
        if not CryptExportKey(hKey, 0, PUBLICKEYBLOB, 0, @PublicKey[0], @BufSize) then
          Exit;
        Result := true;
      finally
        CryptDestroyKey(hKey);
      end;
    finally
      CryptReleaseContext(hProv, 0);
    end;
  except
  end;
end;

class function TdwlCrypt.AsymmetricSigning_HashAndSign(const Bytes, PrivateKey: TBytes; out Signature: TBytes): boolean;
begin
  Result := false;
  try
    var hProv: HCRYPTPROV;
    if not CryptAcquireContext(@hProv, nil, nil, PROV_RSA_AES, CRYPT_VERIFYCONTEXT) then
      Exit;
    try
      //import private key
      var hKey: HCRYPTKEY;
      if not CryptImportKey(hProv, @PrivateKey[0], length(PrivateKey), 0, 0, @hKey) then
        Exit;
      try
        var hHash: HCRYPTHASH;
        if not CryptCreateHash(hProv, CALG_MD5, 0, 0, @hHash) then
          Exit;
        try
          if not CryptHashData(hHash, @Bytes[0], length(Bytes), 0) then
            Exit;
          var BufSize: DWord;
          if not CryptSignHash(hHash, AT_SIGNATURE, nil, 0, nil, @BufSize) then // get size of buf
            Exit;
          SetLength(Signature, BufSize);
          if not CryptSignHash(hHash, AT_SIGNATURE, nil, 0, @Signature[0], @BufSize) then
            Exit;
        finally
          CryptDestroyHash(hHash);
        end;
      finally
        CryptDestroyKey(hKey);
      end;
    finally
      CryptReleaseContext(hProv, 0);
    end;
    Result := true;
  except
  end;
end;

class function TdwlCrypt.AES_Decrypt(var Bytes: TBytes; const Key: TBytes): boolean;
var
  hProv: HCRYPTPROV;
  hKey: HCRYPTKEY;
  dW: DWORD;
  DataSize: DWORD;
begin
  Result := false;
  try
    if CryptAcquireContext(@hProv, nil, nil, PROV_RSA_AES, CRYPT_VERIFYCONTEXT) then
    try
      if not CryptImportKey(hProv, @Key[0], length(Key), 0, 0, @hKey) then
        Exit;
      try
        if not CryptSetKeyParam(hKey, KP_IV, @Key[12], 0) then
          Exit;
        dW := CRYPT_MODE_CBC;
        if not CryptSetKeyParam(hKey, KP_MODE, @dW, 0) then
          Exit;
        DataSize := Length(Bytes);
        if DataSize=0 then
          Exit;
        if not CryptDecrypt(hKey, 0, true, 0, @Bytes[0], @DataSize) then
          Exit;
        SetLength(Bytes, DataSize);
        Result := true;
      finally
        CryptDestroyKey(hKey);
      end;
    finally
      CryptReleaseContext(hProv, 0);
    end;
  except
  end;
end;

class function TdwlCrypt.AES_Decrypt(var S: string; const Key: TBytes): boolean;
var
  Bytes: TBytes;
begin
  Result := false;
  try
    Bytes := LowerHexToBytes(S);
    if AES_Decrypt(Bytes, Key) then
    begin
      S := TEncoding.UTF8.GetString(Bytes);
      Result := true;
    end;
  except
  end;
end;

class function TdwlCrypt.AES_Encrypt(var Bytes: TBytes; const Key: TBytes): boolean;
var
  KeyBufSize: word;
  hProv: HCRYPTPROV;
  hKey: HCRYPTKEY;
  dW: DWORD;
  DataSize: DWORD;
  KeyAlignedDataSize: DWORD;
  BufSize: LongWord;
begin
  Result := false;
  try
    if not CryptAcquireContext(@hProv, nil, nil, PROV_RSA_AES, CRYPT_VERIFYCONTEXT) then
      Exit;
    try
      KeyBufSize := Length(Key)-12;
      if not CryptImportKey(hProv, @Key[0], length(Key), 0, 0, @hKey) then
        Exit;
      try
        if not CryptSetKeyParam(hKey, KP_IV, @Key[12], 0) then
          Exit;
        dW := CRYPT_MODE_CBC;
        if not CryptSetKeyParam(hKey, KP_MODE, @dW, 0) then
          Exit;
        DataSize := length(Bytes);
        if DataSize=0 then
          Exit;
        KeyAlignedDataSize := (((DataSize-1) div KeyBufSize)+1)*KeyBufSize;
        BufSize := KeyAlignedDataSize+KeyBufSize; {extra space for padding full key block}
        SetLength(Bytes, BufSize);
        if not CryptEncrypt(hKey, 0, true, 0, @Bytes[0], @DataSize, BufSize) then
          Exit;
        SetLength(Bytes, DataSize);
        Result := true;
      finally
        CryptDestroyKey(hKey);
      end;
    finally
      CryptReleaseContext(hProv, 0);
    end;
  except
  end;
end;

class function TdwlCrypt.AES_Encrypt(var S: string; const Key: TBytes): boolean;
var
  Bytes: TBytes;
begin
  Result := false;
  try
    Bytes := TEncoding.UTF8.GetBytes(S);
    if AES_Encrypt(Bytes, Key) then
    begin
      S := BytestoLowerHex(Bytes);
      Result := true;
    end;
  except
  end;
end;


end.
