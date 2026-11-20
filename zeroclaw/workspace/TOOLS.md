# Tools

## Shopping and web browsing: browser-use
- Shopping sites (MercadoLibre, Amazon, airlines, bus portals) block plain fetches. For them, use browser-use__run_session, not web_fetch or http_request.
- Always pass profile_id = "<your-browser-use-profile-id>" (onix-shopping, which holds the saved logins).
- Use proxy_country = "co" for Colombian sites (mercadolibre.com.co, Colombian airlines and bus portals), and "us" for amazon.com.
- Ask for structured output with output_schema, e.g. a list of {title, price, currency, shipping_to_colombia, url}. Give the user at most 5 options.
- If the session asks for login or 2FA, stop and tell the user the profile needs re-authentication. Never type passwords.
- NEVER add to cart, check out, buy, book or pay. Purchasing is not enabled yet. If asked, compare options and say that payments come later.
- Sessions cost money. Prefer one well-scoped task over many small ones, and stop sessions when done.
