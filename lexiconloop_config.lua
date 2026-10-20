-- Project URL and publishable (anon) key of the Lexicon Loop Supabase project.
-- The publishable key is meant to be public: row level security in the database
-- decides what a signed-in user can read or write.
return {
    supabase_url = "https://fxfqatxozsqcxdrgtqxr.supabase.co",
    supabase_key = "sb_publishable_dMMF1_EZepUsRgH_EkHe8A_P_to_Ppe",
    -- Optional: Gemini API key for meaning / CEFR. Normally set on the device in
    -- Tools > Lexicon Loop > Gemini API key, which takes precedence over this value.
    gemini_api_key = "",
    default_source_language = "German",
    default_target_language = "Turkish",
    languages = { "German", "Turkish", "English", "French" },
}
