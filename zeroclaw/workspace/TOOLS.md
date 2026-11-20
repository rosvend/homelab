# Tools

## Shopping and web browsing: browser-use
- Shopping sites (MercadoLibre, Amazon, airlines, bus portals) block plain fetches. For them, use browser-use__run_session, not web_fetch or http_request.
- Always pass profile_id = "<your-browser-use-profile-id>" (onix-shopping, which holds the saved logins).
- Use proxy_country = "co" for Colombian sites (mercadolibre.com.co, Colombian airlines and bus portals), and "us" for amazon.com.
- run_session returns right away with status "running" and no output. Then loop: run the shell command `sleep 20 && echo poll N` (N = 1, 2, 3...), then call browser-use__get_session with the session_id. Stop when the status is idle, stopped, timed_out or error, and answer from its output. Don't tell the user it failed while it's still running. Give up after 15 polls and tell the user.
- MercadoLibre price filters go in the path, not a #fragment: https://listado.mercadolibre.com.co/monitor_PriceRange_0-500000 (query words joined with "-"). Tell the browser agent to reject results above the budget.
- Ask for structured output with output_schema, e.g. a list of {title, price, currency, shipping_to_colombia, url}. Give the user at most 5 options.
- If the session asks for login or 2FA, stop and tell the user the profile needs re-authentication. Never type passwords.
- NEVER add to cart, check out, buy, book or pay. Purchasing is not enabled yet. If asked, compare options and say that payments come later.
- Sessions cost money. Prefer one well-scoped task over many small ones, and stop sessions when done.
