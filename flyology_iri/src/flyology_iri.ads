with Ada.Strings.Unbounded;

--  Parses RFC 3986 URI references, RFC 3987 IRI references, and the common
--  WHATWG web URLs. Parse stores one compact serialized reference plus
--  component offsets. Common absolute HTTP(S) validation avoids allocation;
--  normalization and IDNA handling may allocate.
package Flyology_IRI is

   --  Grammar and normalization policy used by the parser.
   --  @enum URI_Syntax RFC 3986 ASCII URI-reference grammar
   --  @enum IRI_Syntax RFC 3987 UTF-8 IRI-reference grammar
   --  @enum Web_URL_Syntax Absolute URL policy for common web schemes
   type Syntax_Kind is (URI_Syntax, IRI_Syntax, Web_URL_Syntax);

   --  Classification of a parsed reference.
   --  @enum Absolute_Reference A reference containing a scheme
   --  @enum Network_Path_Reference A scheme-relative `//authority` reference
   --  @enum Absolute_Path_Reference A reference whose path starts with `/`
   --  @enum Relative_Path_Reference A nonempty relative-path reference
   --  @enum Empty_Reference An empty reference, possibly with query or fragment
   type Reference_Kind is
     (Absolute_Reference,
      Network_Path_Reference,
      Absolute_Path_Reference,
      Relative_Path_Reference,
      Empty_Reference);

   --  Stable parse failure categories.
   --  @enum No_Error Parsing succeeded
   --  @enum Too_Long Input exceeds the caller's maximum length
   --  @enum Invalid_Character Input contains a forbidden character or UTF-8
   --  @enum Invalid_Percent_Encoding A percent sign lacks two hexadecimal digits
   --  @enum Invalid_Scheme A scheme candidate violates the scheme grammar
   --  @enum Invalid_Authority Authority, host, IP literal, or port is malformed
   --  @enum Invalid_Path Path violates the selected reference grammar
   --  @enum Relative_URL Web URL mode requires an absolute URL
   --  @enum Unsupported_URL Web URL mode does not implement this URL form
   type Error_Kind is
     (No_Error,
      Too_Long,
      Invalid_Character,
      Invalid_Percent_Encoding,
      Invalid_Scheme,
      Invalid_Authority,
      Invalid_Path,
      Relative_URL,
      Unsupported_URL);

   --  Byte offset and failure category returned by Diagnose. Offset is one
   --  based relative to the input, or zero when no single byte is responsible.
   --  @field Kind Failure category
   --  @field Offset One-based byte offset, or zero
   type Parse_Error is record
      Kind   : Error_Kind := No_Error;
      Offset : Natural := 0;
   end record;

   --  Default defensive input bound used by parsing operations.
   Default_Max_Length : constant Positive := 8 * 1_024;

   --  Raised by Parse and Resolve when their input is malformed.
   Malformed_Reference : exception;

   --  Compact owned parsed reference. Copies are independent; component
   --  getters return fresh String values.
   type Reference is private;

   --  Validate without constructing a Reference. URI and IRI validation and
   --  the common absolute HTTP(S) fast path do not allocate; other web inputs
   --  may allocate while applying WHATWG normalization and IDNA processing.
   --  @param Input URI, IRI, or URL bytes
   --  @param Syntax Grammar and policy to apply
   --  @param Max_Length Maximum accepted input and serialized byte length
   --  @return True exactly when Diagnose reports No_Error
   function Can_Parse
     (Input      : String;
      Syntax     : Syntax_Kind := IRI_Syntax;
      Max_Length : Positive := Default_Max_Length) return Boolean;

   --  Validate and report the first stable error category and byte offset.
   --  @param Input URI, IRI, or URL bytes
   --  @param Syntax Grammar and policy to apply
   --  @param Max_Length Maximum accepted input and serialized byte length
   --  @return No_Error on success, otherwise the first detected failure
   function Diagnose
     (Input      : String;
      Syntax     : Syntax_Kind := IRI_Syntax;
      Max_Length : Positive := Default_Max_Length) return Parse_Error;

   --  Parse into a compact owned representation. Web URL mode lowercases the
   --  scheme and ASCII host and inserts `/` for an empty HTTP-style path.
   --  @param Input URI, IRI, or URL bytes
   --  @param Syntax Grammar and policy to apply
   --  @param Max_Length Maximum accepted input and serialized byte length
   --  @return Parsed reference
   --  @exception Malformed_Reference Input is invalid
   function Parse
     (Input      : String;
      Syntax     : Syntax_Kind := IRI_Syntax;
      Max_Length : Positive := Default_Max_Length) return Reference;

   --  Parse a web URL using an already parsed absolute web base URL.
   --  @param Input Absolute or relative URL input
   --  @param Base Absolute web URL used for relative resolution
   --  @param Max_Length Maximum accepted input and serialized byte length
   --  @return Parsed absolute web URL
   --  @exception Malformed_Reference Base or input is not a valid web URL
   function Parse
     (Input      : String;
      Base       : Reference;
      Max_Length : Positive := Default_Max_Length) return Reference;

   --  Parse without exceptions, returning a default reference on failure.
   --  @param Input URI, IRI, or URL bytes
   --  @param Value Parsed reference on success, otherwise a default value
   --  @param Error No_Error on success, otherwise the parse failure
   --  @param Syntax Grammar and policy to apply
   --  @param Max_Length Maximum accepted input and serialized byte length
   procedure Try_Parse
     (Input      : String;
      Value      : out Reference;
      Error      : out Parse_Error;
      Syntax     : Syntax_Kind := IRI_Syntax;
      Max_Length : Positive := Default_Max_Length);

   --  Parse a web URL against a base without raising an exception.
   --  @param Input Absolute or relative URL input
   --  @param Base Absolute web URL used for relative resolution
   --  @param Value Parsed absolute URL on success
   --  @param Error No_Error on success, otherwise the parse failure
   --  @param Max_Length Maximum accepted input and serialized byte length
   procedure Try_Parse
     (Input      : String;
      Base       : Reference;
      Value      : out Reference;
      Error      : out Parse_Error;
      Max_Length : Positive := Default_Max_Length);

   --  Resolve a URI or IRI reference against an absolute base using RFC 3986
   --  section 5.2 merging and dot-segment removal.
   --  @param Base Absolute base reference
   --  @param Relative Reference to resolve
   --  @param Max_Length Maximum accepted input and serialized byte length
   --  @return Resolved absolute reference
   --  @exception Malformed_Reference Base is not absolute or result is invalid
   function Resolve
     (Base       : Reference;
      Relative   : String;
      Max_Length : Positive := Default_Max_Length) return Reference;

   --  Resolve to a serialization without constructing a Reference for the
   --  result. This suits a caller that stores resolved references as opaque
   --  bytes: it needs the result validated but never reads its components.
   --  URI and IRI results are validated by Diagnose, which builds nothing.
   --  A web URL result is still parsed, because web mode normalizes and the
   --  normalized serialization is the result. The value equals Image of the
   --  Reference this returns for the same arguments.
   --  @param Base Absolute base reference
   --  @param Relative Reference to resolve
   --  @param Max_Length Maximum accepted input and serialized byte length
   --  @return Resolved absolute reference serialization
   --  @exception Malformed_Reference Base is not absolute or result is invalid
   function Resolve
     (Base       : Reference;
      Relative   : String;
      Max_Length : Positive := Default_Max_Length) return String;

   --  Report whether the reference came from a successful parse. A default
   --  reference and the value Try_Parse returns on failure are both
   --  invalid, which distinguishes a rejected input from a parsed empty
   --  reference without inspecting the reported error.
   --  @param Value Reference to examine
   --  @return True when Parse, Try_Parse or Resolve produced this value
   function Is_Valid (Value : Reference) return Boolean;

   --  Return the selected parsing policy. On failure Try_Parse reports the
   --  syntax it was asked for.
   --  @param Value Parsed reference
   --  @return Syntax used by Parse
   function Syntax (Value : Reference) return Syntax_Kind;

   --  Return the structural reference classification.
   --  @param Value Parsed reference
   --  @return Absolute, network-path, absolute-path, relative-path, or empty
   function Kind (Value : Reference) return Reference_Kind;

   --  Return the serialized reference.
   --  @param Value Parsed reference
   --  @return Stored, possibly normalized serialization
   function Image (Value : Reference) return String;

   --  Return serialized byte length without constructing a String copy.
   --  @param Value Parsed reference
   --  @return Number of bytes in Image
   function Image_Length (Value : Reference) return Natural;

   --  Report whether the reference has a scheme.
   --  @param Value Parsed reference
   --  @return True when Scheme is nonempty
   function Has_Scheme (Value : Reference) return Boolean;

   --  Return the scheme without its colon, or an empty string.
   --  @param Value Parsed reference
   --  @return Scheme component
   function Scheme (Value : Reference) return String;

   --  Report whether `//authority` is present, including an empty authority.
   --  @param Value Parsed reference
   --  @return True when the reference has an authority delimiter
   function Has_Authority (Value : Reference) return Boolean;

   --  Return the complete authority without `//`, or an empty string.
   --  @param Value Parsed reference
   --  @return Authority component
   function Authority (Value : Reference) return String;

   --  Return user information without `@`, or an empty string.
   --  @param Value Parsed reference
   --  @return User-information component
   function Userinfo (Value : Reference) return String;

   --  Return the host without IPv6 brackets, or an empty string.
   --  @param Value Parsed reference
   --  @return Host component
   function Host (Value : Reference) return String;

   --  Return the decimal port without its colon, or an empty string.
   --  @param Value Parsed reference
   --  @return Port component
   function Port (Value : Reference) return String;

   --  Return the path, which may be empty.
   --  @param Value Parsed reference
   --  @return Path component
   function Path (Value : Reference) return String;

   --  Report whether a query delimiter is present, including an empty query.
   --  @param Value Parsed reference
   --  @return True when `?` is present
   function Has_Query (Value : Reference) return Boolean;

   --  Return the query without `?`, or an empty string.
   --  @param Value Parsed reference
   --  @return Query component
   function Query (Value : Reference) return String;

   --  Report whether a fragment delimiter is present, including an empty one.
   --  @param Value Parsed reference
   --  @return True when `#` is present
   function Has_Fragment (Value : Reference) return Boolean;

   --  Return the fragment without `#`, or an empty string.
   --  @param Value Parsed reference
   --  @return Fragment component
   function Fragment (Value : Reference) return String;

   --  Return the normalized network origin for an HTTP or WebSocket URL.
   --  Credentials, path, query, and fragment are omitted. This adapter is
   --  intended for APIs such as Flyology.HTTP.Parse_Origin and
   --  Flyology.HTTP.WebSocket_Client.Parse_Origin.
   --  @param Value Parsed absolute HTTP(S) or WS(S) web URL
   --  @return Scheme, host, and optional nondefault port
   --  @exception Malformed_Reference Value is not an HTTP or WebSocket URL
   function Origin (Value : Reference) return String;

   --  Return an HTTP origin-form request target from a parsed HTTP or
   --  WebSocket URL. The result contains the path and optional query while
   --  deliberately omitting the fragment.
   --  @param Value Parsed absolute HTTP(S) or WS(S) web URL
   --  @return Origin-form path and optional query
   --  @exception Malformed_Reference Value is not an HTTP or WebSocket URL
   function Target (Value : Reference) return String;

private
   type Span is record
      First : Natural := 0;
      Last  : Natural := 0;
   end record;

   type Reference is record
      Text              : Ada.Strings.Unbounded.Unbounded_String;
      Syntax_Value      : Syntax_Kind := IRI_Syntax;
      Kind_Value        : Reference_Kind := Empty_Reference;
      Scheme_Part       : Span;
      Authority_Part    : Span;
      Userinfo_Part     : Span;
      Host_Part         : Span;
      Port_Part         : Span;
      Path_Part         : Span;
      Query_Part        : Span;
      Fragment_Part     : Span;
      Authority_Present : Boolean := False;
      Query_Present     : Boolean := False;
      Fragment_Present  : Boolean := False;
      Valid_Value       : Boolean := False;
   end record;

end Flyology_IRI;
