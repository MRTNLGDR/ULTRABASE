-- Ultrabase platform capabilities that are opt-in in current Supabase images.
-- The upstream PostgreSQL 17 image disables pg_graphql by default on fresh
-- projects. Ultrabase advertises a GraphQL endpoint, so the feature is enabled
-- deliberately and idempotently instead of relying on an old image default.

create extension if not exists pg_graphql;

-- pg_graphql 1.6+ disables introspection by default. Ultrabase Studio includes
-- GraphiQL/API documentation, therefore local loopback installations opt in.
comment on schema public is e'@graphql({"introspection": true})';
