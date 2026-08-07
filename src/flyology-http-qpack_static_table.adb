package body Flyology.HTTP.QPACK_Static_Table
  with SPARK_Mode => On
is
   function Name (Index : Static_Index) return String is
     (case Index is
         when 0 => ":authority",
         when 1 => ":path",
         when 2 => "age",
         when 3 => "content-disposition",
         when 4 => "content-length",
         when 5 => "cookie",
         when 6 => "date",
         when 7 => "etag",
         when 8 => "if-modified-since",
         when 9 => "if-none-match",
         when 10 => "last-modified",
         when 11 => "link",
         when 12 => "location",
         when 13 => "referer",
         when 14 => "set-cookie",
         when 15 .. 21 => ":method",
         when 22 .. 23 => ":scheme",
         when 24 .. 28 => ":status",
         when 29 .. 30 => "accept",
         when 31 => "accept-encoding",
         when 32 => "accept-ranges",
         when 33 .. 34 => "access-control-allow-headers",
         when 35 => "access-control-allow-origin",
         when 36 .. 41 => "cache-control",
         when 42 .. 43 => "content-encoding",
         when 44 .. 54 => "content-type",
         when 55 => "range",
         when 56 .. 58 => "strict-transport-security",
         when 59 .. 60 => "vary",
         when 61 => "x-content-type-options",
         when 62 => "x-xss-protection",
         when 63 .. 71 => ":status",
         when 72 => "accept-language",
         when 73 .. 74 => "access-control-allow-credentials",
         when 75 => "access-control-allow-headers",
         when 76 .. 78 => "access-control-allow-methods",
         when 79 => "access-control-expose-headers",
         when 80 => "access-control-request-headers",
         when 81 .. 82 => "access-control-request-method",
         when 83 => "alt-svc",
         when 84 => "authorization",
         when 85 => "content-security-policy",
         when 86 => "early-data",
         when 87 => "expect-ct",
         when 88 => "forwarded",
         when 89 => "if-range",
         when 90 => "origin",
         when 91 => "purpose",
         when 92 => "server",
         when 93 => "timing-allow-origin",
         when 94 => "upgrade-insecure-requests",
         when 95 => "user-agent",
         when 96 => "x-forwarded-for",
         when 97 .. 98 => "x-frame-options");

   function Value (Index : Static_Index) return String is
     (case Index is
         when 0 => "",
         when 1 => "/",
         when 2 => "0",
         when 3 => "",
         when 4 => "0",
         when 5 .. 14 => "",
         when 15 => "CONNECT",
         when 16 => "DELETE",
         when 17 => "GET",
         when 18 => "HEAD",
         when 19 => "OPTIONS",
         when 20 => "POST",
         when 21 => "PUT",
         when 22 => "http",
         when 23 => "https",
         when 24 => "103",
         when 25 => "200",
         when 26 => "304",
         when 27 => "404",
         when 28 => "503",
         when 29 => "*/*",
         when 30 => "application/dns-message",
         when 31 => "gzip, deflate, br",
         when 32 => "bytes",
         when 33 => "cache-control",
         when 34 => "content-type",
         when 35 => "*",
         when 36 => "max-age=0",
         when 37 => "max-age=2592000",
         when 38 => "max-age=604800",
         when 39 => "no-cache",
         when 40 => "no-store",
         when 41 => "public, max-age=31536000",
         when 42 => "br",
         when 43 => "gzip",
         when 44 => "application/dns-message",
         when 45 => "application/javascript",
         when 46 => "application/json",
         when 47 => "application/x-www-form-urlencoded",
         when 48 => "image/gif",
         when 49 => "image/jpeg",
         when 50 => "image/png",
         when 51 => "text/css",
         when 52 => "text/html; charset=utf-8",
         when 53 => "text/plain",
         when 54 => "text/plain;charset=utf-8",
         when 55 => "bytes=0-",
         when 56 => "max-age=31536000",
         when 57 => "max-age=31536000; includesubdomains",
         when 58 => "max-age=31536000; includesubdomains; preload",
         when 59 => "accept-encoding",
         when 60 => "origin",
         when 61 => "nosniff",
         when 62 => "1; mode=block",
         when 63 => "100",
         when 64 => "204",
         when 65 => "206",
         when 66 => "302",
         when 67 => "400",
         when 68 => "403",
         when 69 => "421",
         when 70 => "425",
         when 71 => "500",
         when 72 => "",
         when 73 => "FALSE",
         when 74 => "TRUE",
         when 75 => "*",
         when 76 => "get",
         when 77 => "get, post, options",
         when 78 => "options",
         when 79 => "content-length",
         when 80 => "content-type",
         when 81 => "get",
         when 82 => "post",
         when 83 => "clear",
         when 84 => "",
         when 85 => "script-src 'none'; object-src 'none'; base-uri 'none'",
         when 86 => "1",
         when 87 .. 90 => "",
         when 91 => "prefetch",
         when 92 => "",
         when 93 => "*",
         when 94 => "1",
         when 95 .. 96 => "",
         when 97 => "deny",
         when 98 => "sameorigin");

   function Find_Exact
     (Field_Name  : String;
      Field_Value : String) return Lookup_Result
   is
   begin
      for Index in Static_Index loop
         if Name (Index) = Field_Name and then Value (Index) = Field_Value then
            return (Found => True, Index => Index);
         end if;
      end loop;
      return (others => <>);
   end Find_Exact;

   function Find_Name (Field_Name : String) return Lookup_Result
   is
   begin
      for Index in Static_Index loop
         if Name (Index) = Field_Name then
            return (Found => True, Index => Index);
         end if;
      end loop;
      return (others => <>);
   end Find_Name;
end Flyology.HTTP.QPACK_Static_Table;
