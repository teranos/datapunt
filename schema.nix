# The fields a competitor teardown may carry, and nothing else.

# `type` is observed from the 27 teardowns, not chosen.
# `question` is the decision the field serves, and is null until someone writes
# it. A field that cannot name one is a field to delete rather than to fill.

# absentOrString is the schema's own idiom: `false` for confirmed absent, a
# string for the value when it is there. null stays distinct from both.

let
  b = q: { type = "bool"; question = q; };
  s = q: { type = "string"; question = q; };
  a = q: { type = "absentOrString"; question = q; };
  l = q: { type = "list"; question = q; };
  e = values: q: { type = "enum"; inherit values; question = q; };
in
{
  url = s null;
  parent = s null;
  fetched = s null;
  brand = s null;
  audience = s null;
  city = l null;
  languages = l null;
  first_captured = s null;
  last_updated = s null;
  niche_landing_pages = l null;
  prices_on_homepage = b null;
  serp_appearances = { type = "listOfMaps"; question = null; };

  cta = {
    form = b null;
    phone = s null;
    whatsapp = a null;
  };

  pricing = {
    model = e [ "hourly" "flat" "from-price" "per-manhour" "mixed" "quote-only" ] null;
    published = a null;
    published_rates = l null;
    hourly = s null;
    from_price = s null;
    unit = e [ "uur" "manuur" "per-woning" ] null;
    supplies_included = b null;
    travel_cost = b null;
    vat_stated = b null;
  };

  services = {
    office = b null;
    move_out = b null;
    recurring_residential = b null;
    windows = b null;
    airbnb_turnover = b null;
    gutters = b null;
    garden = b null;
  };

  terms = {
    minimum = a null;
    notice = s null;
    cancellation = s null;
    trial = s null;
  };

  trust = {
    certifications = l null;
    employment = e [ "employees" "platform" "mixed" ] null;
    insured = b null;
    vog = b null;
    key_handling = a null;
    cao = b null;
  };

  tracking = {
    gtm = l null;
    ga4 = l null;
    google_ads = l null;
    meta_pixel = l null;
    server_side_tag_gateway = l null;
    other = l null;
  };

  running_ads = {
    google = b null;
    meta = b null;
  };

  security = {
    hsts = a null;
    csp = a null;
    x_frame_options = a null;
    x_content_type_options = a null;
    referrer_policy = a null;
  };

  privacy = {
    statement_url = s null;
    statement_dated = s null;
    law_cited = e [ "avg" "wbp" "none" ] null;
    legal_basis_stated = b null;
    retention_periods_stated = b null;
    data_subject_rights_listed = a null;
    supervisory_authority_named = b null;
    controller_identified = a null;
    cookie_consent_mechanism = s null;
    cmp = s null;
    consent_banner = b null;
    template_origin = s null;
    defects = l null;
  };

  registration = {
    kvk = a null;
    btw = a null;
  };

  tech = {
    stack = s null;
    server = s null;
    cdn = s null;
  };

  socials = {
    facebook = a null;
    instagram = a null;
    linkedin = s null;
    tiktok = a null;
    youtube = a null;
  };

  structured_data = {
    local_business = a null;
  };
}
