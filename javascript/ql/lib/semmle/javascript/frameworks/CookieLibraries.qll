/**
 * Provides classes for reasoning about cookies.
 */

import javascript

/**
 * Classes and predicates for reasoning about writes to cookies.
 */
module CookieWrites {
  /**
   * A write to a cookie.
   */
  abstract class CookieWrite extends DataFlow::Node {
    /**
     * Holds if this cookie is secure, i.e. only transmitted over SSL.
     */
    abstract predicate isSecure();

    /**
     * Holds if this cookie is HttpOnly, i.e. not accessible by JavaScript.
     */
    abstract predicate isHttpOnly();

    /**
     * Holds if the cookie is likely an authentication cookie or otherwise sensitive.
     * Can never hold for client-side cookies. TODO: Or can it...?
     */
    abstract predicate isSensitive();
  }

  /**
   * The flag that indicates that a cookie is secure.
   */
  string secure() { result = "secure" }

  /**
   * The flag that indicates that a cookie is HttpOnly.
   */
  string httpOnly() { result = "httpOnly" }
}

/**
 * A model of the `js-cookie` library (https://github.com/js-cookie/js-cookie).
 */
private module JsCookie {
  /**
   * Gets a function call that invokes method `name` of the `js-cookie` library.
   */
  DataFlow::CallNode libMemberCall(string name) {
    result = DataFlow::globalVarRef("Cookie").getAMemberCall(name) or
    result = DataFlow::globalVarRef("Cookie").getAMemberCall("noConflict").getAMemberCall(name) or
    result = DataFlow::moduleMember("js-cookie", name).getACall()
  }

  class ReadAccess extends PersistentReadAccess, DataFlow::CallNode {
    ReadAccess() { this = libMemberCall("get") }

    override PersistentWriteAccess getAWrite() {
      getArgument(0).mayHaveStringValue(result.(WriteAccess).getKey())
    }
  }

  class WriteAccess extends PersistentWriteAccess, DataFlow::CallNode, CookieWrites::CookieWrite {
    WriteAccess() { this = libMemberCall("set") }

    string getKey() { getArgument(0).mayHaveStringValue(result) }

    override DataFlow::Node getValue() { result = getArgument(1) }

    override predicate isSecure() {
      // A cookie is secure if there are cookie options with the `secure` flag set to `true`.
      this.getOptionArgument(2, CookieWrites::secure()).mayHaveBooleanValue(true)
    }

    override predicate isSensitive() {
      HeuristicNames::nameIndicatesSensitiveData(any(string s |
          this.getArgument(0).mayHaveStringValue(s)
        ), _)
    }

    override predicate isHttpOnly() { none() } // js-cookie is browser side library and doesn't support HttpOnly
  }
}

/**
 * A model of the `browser-cookies` library (https://github.com/voltace/browser-cookies).
 */
private module BrowserCookies {
  /**
   * Gets a function call that invokes method `name` of the `browser-cookies` library.
   */
  DataFlow::CallNode libMemberCall(string name) {
    result = DataFlow::moduleMember("browser-cookies", name).getACall()
  }

  class ReadAccess extends PersistentReadAccess, DataFlow::CallNode {
    ReadAccess() { this = libMemberCall("get") }

    override PersistentWriteAccess getAWrite() {
      getArgument(0).mayHaveStringValue(result.(WriteAccess).getKey())
    }
  }

  class WriteAccess extends PersistentWriteAccess, DataFlow::CallNode {
    // TODO: CookieWrite
    WriteAccess() { this = libMemberCall("set") }

    string getKey() { getArgument(0).mayHaveStringValue(result) }

    override DataFlow::Node getValue() { result = getArgument(1) }
  }
}

/**
 * A model of the `cookie` library (https://github.com/jshttp/cookie).
 */
private module LibCookie {
  /**
   * Gets a function call that invokes method `name` of the `cookie` library.
   */
  DataFlow::CallNode libMemberCall(string name) {
    result = DataFlow::moduleMember("cookie", name).getACall()
  }

  class ReadAccess extends PersistentReadAccess {
    string key;

    ReadAccess() { this = libMemberCall("parse").getAPropertyRead(key) }

    override PersistentWriteAccess getAWrite() { key = result.(WriteAccess).getKey() }
  }

  class WriteAccess extends PersistentWriteAccess, DataFlow::CallNode {
    // TODO: CookieWrite
    WriteAccess() { this = libMemberCall("serialize") }

    string getKey() { getArgument(0).mayHaveStringValue(result) }

    override DataFlow::Node getValue() { result = getArgument(1) }
  }
}

/**
 * A model of cookies in an express application.
 */
private module ExpressCookies {
  /**
   * A cookie set using `response.cookie` from `express` module (https://expressjs.com/en/api.html#res.cookie).
   */
  private class InsecureExpressCookieResponse extends CookieWrites::CookieWrite,
    DataFlow::MethodCallNode {
    InsecureExpressCookieResponse() { this.asExpr() instanceof Express::SetCookie }

    override predicate isSecure() {
      // A cookie is secure if there are cookie options with the `secure` flag set to `true`.
      // The default is `false`.
      this.getOptionArgument(2, CookieWrites::secure()).mayHaveBooleanValue(true)
    }

    override predicate isSensitive() {
      HeuristicNames::nameIndicatesSensitiveData(any(string s |
          this.getArgument(0).mayHaveStringValue(s)
        ), _)
      or
      this.getArgument(0).asExpr() instanceof SensitiveExpr
    }

    override predicate isHttpOnly() {
      // A cookie is httpOnly if there are cookie options with the `httpOnly` flag set to `true`.
      // The default is `false`.
      this.getOptionArgument(2, CookieWrites::httpOnly()).mayHaveBooleanValue(true)
    }
  }

  /**
   * A cookie set using the `express` module `cookie-session` (https://github.com/expressjs/cookie-session).
   */
  class InsecureCookieSession extends ExpressLibraries::CookieSession::MiddlewareInstance,
    CookieWrites::CookieWrite {
    private DataFlow::Node getCookieFlagValue(string flag) {
      result = this.getOptionArgument(0, flag)
    }

    override predicate isSecure() {
      // The flag `secure` is set to `false` by default for HTTP, `true` by default for HTTPS (https://github.com/expressjs/cookie-session#cookie-options).
      // A cookie is secure if the `secure` flag is not explicitly set to `false`.
      not getCookieFlagValue(CookieWrites::secure()).mayHaveBooleanValue(false)
    }

    override predicate isSensitive() {
      any() // It is a session cookie, likely auth sensitive
    }

    override predicate isHttpOnly() {
      // The flag `httpOnly` is set to `true` by default (https://github.com/expressjs/cookie-session#cookie-options).
      // A cookie is httpOnly if the `httpOnly` flag is not explicitly set to `false`.
      not getCookieFlagValue(CookieWrites::httpOnly()).mayHaveBooleanValue(false)
    }
  }

  /**
   * A cookie set using the `express` module `express-session` (https://github.com/expressjs/session).
   */
  class InsecureExpressSessionCookie extends ExpressLibraries::ExpressSession::MiddlewareInstance,
    CookieWrites::CookieWrite {
    private DataFlow::Node getCookieFlagValue(string flag) {
      result = this.getOption("cookie").getALocalSource().getAPropertyWrite(flag).getRhs()
    }

    override predicate isSecure() {
      // The flag `secure` is not set by default (https://github.com/expressjs/session#Cookiesecure).
      // The default value for cookie options is { path: '/', httpOnly: true, secure: false, maxAge: null }.
      // A cookie is secure if there are the cookie options with the `secure` flag set to `true` or to `auto`.
      getCookieFlagValue(CookieWrites::secure()).mayHaveBooleanValue(true) or
      getCookieFlagValue(CookieWrites::secure()).mayHaveStringValue("auto")
    }

    override predicate isSensitive() {
      any() // It is a session cookie, likely auth sensitive
    }

    override predicate isHttpOnly() {
      // The flag `httpOnly` is set by default (https://github.com/expressjs/session#Cookiesecure).
      // The default value for cookie options is { path: '/', httpOnly: true, secure: false, maxAge: null }.
      // A cookie is httpOnly if the `httpOnly` flag is not explicitly set to `false`.
      not getCookieFlagValue(CookieWrites::httpOnly()).mayHaveBooleanValue(false)
    }
  }
}

/**
 * A cookie set using `Set-Cookie` header of an `HTTP` response, where a raw header is used.
 * (https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Set-Cookie).
 * This class does not model the Express implementation of `HTTP::CookieDefintion`
 * as the express implementation does not use raw headers.
 *
 * In case an array is passed `setHeader("Set-Cookie", [...]` it sets multiple cookies.
 * We model a `CookieWrite` for each array element.
 */
private class HTTPCookieWrite extends CookieWrites::CookieWrite {
  string header;

  HTTPCookieWrite() {
    exists(HTTP::CookieDefinition setCookie |
      this.asExpr() = setCookie.getHeaderArgument() and
      not this instanceof DataFlow::ArrayCreationNode
      or
      this = setCookie.getHeaderArgument().flow().(DataFlow::ArrayCreationNode).getAnElement()
    ) and
    header =
      [
        any(string s | this.mayHaveStringValue(s)),
        this.(StringOps::ConcatenationRoot).getConstantStringParts()
      ]
  }

  override predicate isSecure() {
    // A cookie is secure if the `secure` flag is specified in the cookie definition.
    //  The default is `false`.
    hasCookieAttribute(header, CookieWrites::secure())
  }

  override predicate isHttpOnly() {
    // A cookie is httpOnly if the `httpOnly` flag is specified in the cookie definition.
    // The default is `false`.
    hasCookieAttribute(header, CookieWrites::httpOnly())
  }

  override predicate isSensitive() {
    HeuristicNames::nameIndicatesSensitiveData(getCookieName(header), _)
  }

  /**
   * Gets cookie name from a `Set-Cookie` header value.
   * The header value always starts with `<cookie-name>=<cookie-value>` optionally followed by attributes:
   * `<cookie-name>=<cookie-value>; Domain=<domain-value>; Secure; HttpOnly`
   */
  bindingset[s]
  private string getCookieName(string s) {
    result = s.regexpCapture("\\s*\\b([^=\\s]*)\\b\\s*=.*", 1)
  }

  /**
   * Holds if the `Set-Cookie` header value contains the specified attribute
   * 1. The attribute is case insensitive
   * 2. It always starts with a pair `<cookie-name>=<cookie-value>`.
   *    If the attribute is present there must be `;` after the pair.
   *    Other attributes like `Domain=`, `Path=`, etc. may come after the pair:
   *    `<cookie-name>=<cookie-value>; Domain=<domain-value>; Secure; HttpOnly`
   * See `https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Set-Cookie`
   */
  bindingset[s, attribute]
  private predicate hasCookieAttribute(string s, string attribute) {
    s.regexpMatch("(?i).*;\\s*" + attribute + "\\b\\s*;?.*$")
  }
}
