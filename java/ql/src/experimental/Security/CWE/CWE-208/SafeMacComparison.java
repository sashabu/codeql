public boolean check(byte[] signature, byte[] message, SecretKey key) throws Exception {
    Mac mac = Mac.getInstance("HmacSHA256");
    mac.init(new SecretKeySpec(key.getEncoded(), "HmacSHA256"));
    byte[] actual = mac.doFinal(message);
    return MessageDigest.isEqual(signature, actual);
}