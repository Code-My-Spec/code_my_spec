--
-- PostgreSQL database dump
--

-- Dumped from database version 15.13 (Homebrew)
-- Dumped by pg_dump version 15.5 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: citext; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;


--
-- Name: EXTENSION citext; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION citext IS 'data type for case-insensitive character strings';


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.accounts (
    name character varying(255) NOT NULL,
    slug character varying(255),
    type character varying(255) DEFAULT 'personal'::character varying NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    id uuid NOT NULL
);


--
-- Name: client_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.client_users (
    id bigint NOT NULL,
    email character varying(255),
    oauth_token bytea,
    oauth_refresh_token bytea,
    oauth_expires_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: client_users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.client_users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: client_users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.client_users_id_seq OWNED BY public.client_users.id;


--
-- Name: component_tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.component_tags (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    project_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: component_tags_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.component_tags_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: component_tags_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.component_tags_id_seq OWNED BY public.component_tags.id;


--
-- Name: components; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.components (
    name character varying(255) NOT NULL,
    type character varying(255),
    module_name character varying(255) NOT NULL,
    description text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    module_status jsonb,
    id uuid NOT NULL,
    parent_component_id uuid,
    component_status character varying(255),
    project_id uuid NOT NULL,
    synced_at timestamp(0) without time zone,
    account_id uuid NOT NULL
);


--
-- Name: content_admin; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.content_admin (
    id bigint NOT NULL,
    raw_content text,
    processed_content text,
    parse_status character varying(255) NOT NULL,
    parse_errors jsonb,
    metadata jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    project_id uuid NOT NULL,
    account_id uuid NOT NULL
);


--
-- Name: content_admin_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.content_admin_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: content_admin_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.content_admin_id_seq OWNED BY public.content_admin.id;


--
-- Name: content_tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.content_tags (
    id bigint NOT NULL,
    content_id bigint NOT NULL,
    tag_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: content_tags_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.content_tags_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: content_tags_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.content_tags_id_seq OWNED BY public.content_tags.id;


--
-- Name: criteria; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.criteria (
    id bigint NOT NULL,
    description text NOT NULL,
    "position" integer,
    verified boolean DEFAULT false NOT NULL,
    verified_at timestamp(0) without time zone,
    story_id bigint NOT NULL,
    project_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    account_id uuid NOT NULL
);


--
-- Name: criteria_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.criteria_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: criteria_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.criteria_id_seq OWNED BY public.criteria.id;


--
-- Name: dependencies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dependencies (
    id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    source_component_id uuid NOT NULL,
    target_component_id uuid NOT NULL
);


--
-- Name: dependencies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.dependencies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: dependencies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.dependencies_id_seq OWNED BY public.dependencies.id;


--
-- Name: file_edits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.file_edits (
    id uuid NOT NULL,
    external_session_id character varying(255) NOT NULL,
    file_path character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    agent_id character varying(255)
);


--
-- Name: integrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.integrations (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    provider character varying(255) NOT NULL,
    access_token bytea NOT NULL,
    refresh_token bytea,
    expires_at timestamp without time zone NOT NULL,
    granted_scopes character varying(255)[] DEFAULT ARRAY[]::character varying[],
    provider_metadata jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: integrations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.integrations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: integrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.integrations_id_seq OWNED BY public.integrations.id;


--
-- Name: interaction_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.interaction_events (
    id bigint NOT NULL,
    interaction_id uuid NOT NULL,
    event_type character varying(255) NOT NULL,
    data jsonb,
    metadata jsonb,
    sent_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: interaction_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.interaction_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: interaction_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.interaction_events_id_seq OWNED BY public.interaction_events.id;


--
-- Name: interactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.interactions (
    id uuid NOT NULL,
    step_name character varying(255),
    command jsonb NOT NULL,
    result jsonb,
    completed_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    session_id uuid NOT NULL
);


--
-- Name: invitations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invitations (
    id bigint NOT NULL,
    token character varying(255) NOT NULL,
    email character varying(255) NOT NULL,
    role character varying(255) NOT NULL,
    expires_at timestamp(0) without time zone NOT NULL,
    accepted_at timestamp(0) without time zone,
    cancelled_at timestamp(0) without time zone,
    invited_by_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    account_id uuid NOT NULL
);


--
-- Name: invitations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.invitations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: invitations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.invitations_id_seq OWNED BY public.invitations.id;


--
-- Name: members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.members (
    id bigint NOT NULL,
    role character varying(255) DEFAULT 'member'::character varying NOT NULL,
    user_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    account_id uuid NOT NULL
);


--
-- Name: members_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.members_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: members_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.members_id_seq OWNED BY public.members.id;


--
-- Name: oauth_access_grants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oauth_access_grants (
    id bigint NOT NULL,
    token character varying(255) NOT NULL,
    expires_in integer NOT NULL,
    redirect_uri character varying(255) NOT NULL,
    revoked_at timestamp(0) without time zone,
    scopes character varying(255),
    resource_owner_id bigint,
    application_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: oauth_access_grants_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.oauth_access_grants_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: oauth_access_grants_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.oauth_access_grants_id_seq OWNED BY public.oauth_access_grants.id;


--
-- Name: oauth_access_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oauth_access_tokens (
    id bigint NOT NULL,
    token character varying(255) NOT NULL,
    refresh_token character varying(255),
    expires_in integer,
    revoked_at timestamp(0) without time zone,
    scopes character varying(255),
    previous_refresh_token character varying(255) DEFAULT ''::character varying NOT NULL,
    resource_owner_id bigint,
    application_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: oauth_access_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.oauth_access_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: oauth_access_tokens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.oauth_access_tokens_id_seq OWNED BY public.oauth_access_tokens.id;


--
-- Name: oauth_applications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oauth_applications (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    uid character varying(255) NOT NULL,
    secret character varying(255) DEFAULT ''::character varying NOT NULL,
    redirect_uri character varying(255) NOT NULL,
    scopes character varying(255) DEFAULT ''::character varying NOT NULL,
    owner_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: oauth_applications_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.oauth_applications_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: oauth_applications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.oauth_applications_id_seq OWNED BY public.oauth_applications.id;


--
-- Name: problems; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.problems (
    id bigint NOT NULL,
    severity character varying(255) NOT NULL,
    source_type character varying(255) NOT NULL,
    source character varying(255) NOT NULL,
    file_path character varying(255) NOT NULL,
    line integer,
    message text NOT NULL,
    category character varying(255) NOT NULL,
    rule character varying(255),
    metadata jsonb,
    project_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: problems_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.problems_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: problems_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.problems_id_seq OWNED BY public.problems.id;


--
-- Name: projects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.projects (
    name character varying(255),
    description text,
    code_repo character varying(255),
    docs_repo character varying(255),
    status character varying(255),
    setup_error character varying(255),
    user_id integer,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    module_name character varying(255),
    google_analytics_property_id character varying(255),
    client_api_url character varying(255),
    deploy_key character varying(255),
    id uuid NOT NULL,
    account_id uuid
);


--
-- Name: push_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.push_subscriptions (
    id uuid NOT NULL,
    user_id bigint NOT NULL,
    endpoint text NOT NULL,
    p256dh_key text NOT NULL,
    auth_key text NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: requirements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.requirements (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    description text NOT NULL,
    checker_module character varying(255) NOT NULL,
    satisfied_by character varying(255),
    satisfied boolean DEFAULT false NOT NULL,
    checked_at timestamp(0) without time zone,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    component_id uuid,
    artifact_type character varying(255) DEFAULT 'specification'::character varying NOT NULL,
    score double precision,
    story_id bigint,
    project_id uuid,
    scope character varying(255) DEFAULT 'local'::character varying
);


--
-- Name: requirements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.requirements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: requirements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.requirements_id_seq OWNED BY public.requirements.id;


--
-- Name: rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rules (
    id bigint NOT NULL,
    name character varying(255),
    content text,
    component_type character varying(255),
    session_type character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    account_id uuid
);


--
-- Name: rules_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.rules_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: rules_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.rules_id_seq OWNED BY public.rules.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    type character varying(255),
    environment_id character varying(255),
    status character varying(255),
    state jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    environment_type character varying,
    agent character varying,
    context_id bigint,
    interactions jsonb,
    user_id bigint NOT NULL,
    external_conversation_id character varying(255),
    execution_mode character varying(255) DEFAULT 'manual'::character varying,
    component_id uuid,
    project_id uuid,
    id uuid NOT NULL,
    session_id uuid,
    account_id uuid,
    environment jsonb
);


--
-- Name: stories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stories (
    id bigint NOT NULL,
    title character varying(255),
    description text,
    acceptance_criteria character varying(255)[],
    status character varying(255),
    locked_at timestamp(0) without time zone,
    lock_expires_at timestamp(0) without time zone,
    locked_by bigint,
    first_version_id bigint NOT NULL,
    current_version_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    component_id uuid,
    project_id uuid,
    account_id uuid,
    priority integer
);


--
-- Name: stories_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stories_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stories_id_seq OWNED BY public.stories.id;


--
-- Name: story_tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.story_tags (
    id bigint NOT NULL,
    tag_id bigint NOT NULL,
    story_id bigint NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: story_tags_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.story_tags_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: story_tags_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.story_tags_id_seq OWNED BY public.story_tags.id;


--
-- Name: tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tags (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    slug character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: tags_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tags_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tags_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tags_id_seq OWNED BY public.tags.id;


--
-- Name: user_preferences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_preferences (
    id bigint NOT NULL,
    token character varying(255),
    user_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    active_project_id uuid,
    active_account_id uuid
);


--
-- Name: user_preferences_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.user_preferences_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_preferences_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.user_preferences_id_seq OWNED BY public.user_preferences.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    email public.citext NOT NULL,
    hashed_password character varying(255),
    confirmed_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: users_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users_tokens (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    token bytea NOT NULL,
    context character varying(255) NOT NULL,
    sent_to character varying(255),
    authenticated_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: users_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_tokens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_tokens_id_seq OWNED BY public.users_tokens.id;


--
-- Name: versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.versions (
    id bigint NOT NULL,
    event character varying(10) NOT NULL,
    item_type character varying(255) NOT NULL,
    item_id integer,
    item_changes jsonb NOT NULL,
    originator_id bigint,
    origin character varying(50),
    meta jsonb,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.versions_id_seq OWNED BY public.versions.id;


--
-- Name: client_users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_users ALTER COLUMN id SET DEFAULT nextval('public.client_users_id_seq'::regclass);


--
-- Name: component_tags id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_tags ALTER COLUMN id SET DEFAULT nextval('public.component_tags_id_seq'::regclass);


--
-- Name: content_admin id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_admin ALTER COLUMN id SET DEFAULT nextval('public.content_admin_id_seq'::regclass);


--
-- Name: content_tags id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_tags ALTER COLUMN id SET DEFAULT nextval('public.content_tags_id_seq'::regclass);


--
-- Name: criteria id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.criteria ALTER COLUMN id SET DEFAULT nextval('public.criteria_id_seq'::regclass);


--
-- Name: dependencies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dependencies ALTER COLUMN id SET DEFAULT nextval('public.dependencies_id_seq'::regclass);


--
-- Name: integrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integrations ALTER COLUMN id SET DEFAULT nextval('public.integrations_id_seq'::regclass);


--
-- Name: interaction_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interaction_events ALTER COLUMN id SET DEFAULT nextval('public.interaction_events_id_seq'::regclass);


--
-- Name: invitations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitations ALTER COLUMN id SET DEFAULT nextval('public.invitations_id_seq'::regclass);


--
-- Name: members id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.members ALTER COLUMN id SET DEFAULT nextval('public.members_id_seq'::regclass);


--
-- Name: oauth_access_grants id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_access_grants ALTER COLUMN id SET DEFAULT nextval('public.oauth_access_grants_id_seq'::regclass);


--
-- Name: oauth_access_tokens id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_access_tokens ALTER COLUMN id SET DEFAULT nextval('public.oauth_access_tokens_id_seq'::regclass);


--
-- Name: oauth_applications id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_applications ALTER COLUMN id SET DEFAULT nextval('public.oauth_applications_id_seq'::regclass);


--
-- Name: problems id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.problems ALTER COLUMN id SET DEFAULT nextval('public.problems_id_seq'::regclass);


--
-- Name: requirements id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.requirements ALTER COLUMN id SET DEFAULT nextval('public.requirements_id_seq'::regclass);


--
-- Name: rules id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rules ALTER COLUMN id SET DEFAULT nextval('public.rules_id_seq'::regclass);


--
-- Name: stories id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stories ALTER COLUMN id SET DEFAULT nextval('public.stories_id_seq'::regclass);


--
-- Name: story_tags id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.story_tags ALTER COLUMN id SET DEFAULT nextval('public.story_tags_id_seq'::regclass);


--
-- Name: tags id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tags ALTER COLUMN id SET DEFAULT nextval('public.tags_id_seq'::regclass);


--
-- Name: user_preferences id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_preferences ALTER COLUMN id SET DEFAULT nextval('public.user_preferences_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: users_tokens id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_tokens ALTER COLUMN id SET DEFAULT nextval('public.users_tokens_id_seq'::regclass);


--
-- Name: versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.versions ALTER COLUMN id SET DEFAULT nextval('public.versions_id_seq'::regclass);


--
-- Name: accounts accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_pkey PRIMARY KEY (id);


--
-- Name: client_users client_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.client_users
    ADD CONSTRAINT client_users_pkey PRIMARY KEY (id);


--
-- Name: component_tags component_tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_tags
    ADD CONSTRAINT component_tags_pkey PRIMARY KEY (id);


--
-- Name: components components_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.components
    ADD CONSTRAINT components_pkey PRIMARY KEY (id);


--
-- Name: content_admin content_admin_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_admin
    ADD CONSTRAINT content_admin_pkey PRIMARY KEY (id);


--
-- Name: content_tags content_tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_tags
    ADD CONSTRAINT content_tags_pkey PRIMARY KEY (id);


--
-- Name: criteria criteria_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.criteria
    ADD CONSTRAINT criteria_pkey PRIMARY KEY (id);


--
-- Name: dependencies dependencies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dependencies
    ADD CONSTRAINT dependencies_pkey PRIMARY KEY (id);


--
-- Name: file_edits file_edits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_edits
    ADD CONSTRAINT file_edits_pkey PRIMARY KEY (id);


--
-- Name: integrations integrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integrations
    ADD CONSTRAINT integrations_pkey PRIMARY KEY (id);


--
-- Name: interaction_events interaction_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interaction_events
    ADD CONSTRAINT interaction_events_pkey PRIMARY KEY (id);


--
-- Name: interactions interactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interactions
    ADD CONSTRAINT interactions_pkey PRIMARY KEY (id);


--
-- Name: invitations invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitations
    ADD CONSTRAINT invitations_pkey PRIMARY KEY (id);


--
-- Name: members members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.members
    ADD CONSTRAINT members_pkey PRIMARY KEY (id);


--
-- Name: oauth_access_grants oauth_access_grants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_access_grants
    ADD CONSTRAINT oauth_access_grants_pkey PRIMARY KEY (id);


--
-- Name: oauth_access_tokens oauth_access_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_access_tokens
    ADD CONSTRAINT oauth_access_tokens_pkey PRIMARY KEY (id);


--
-- Name: oauth_applications oauth_applications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_applications
    ADD CONSTRAINT oauth_applications_pkey PRIMARY KEY (id);


--
-- Name: problems problems_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.problems
    ADD CONSTRAINT problems_pkey PRIMARY KEY (id);


--
-- Name: projects projects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_pkey PRIMARY KEY (id);


--
-- Name: push_subscriptions push_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.push_subscriptions
    ADD CONSTRAINT push_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: requirements requirements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.requirements
    ADD CONSTRAINT requirements_pkey PRIMARY KEY (id);


--
-- Name: rules rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rules
    ADD CONSTRAINT rules_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: stories stories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stories
    ADD CONSTRAINT stories_pkey PRIMARY KEY (id);


--
-- Name: story_tags story_tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.story_tags
    ADD CONSTRAINT story_tags_pkey PRIMARY KEY (id);


--
-- Name: tags tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT tags_pkey PRIMARY KEY (id);


--
-- Name: user_preferences user_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_preferences
    ADD CONSTRAINT user_preferences_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: users_tokens users_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_tokens
    ADD CONSTRAINT users_tokens_pkey PRIMARY KEY (id);


--
-- Name: versions versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.versions
    ADD CONSTRAINT versions_pkey PRIMARY KEY (id);


--
-- Name: accounts_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX accounts_slug_index ON public.accounts USING btree (slug);


--
-- Name: accounts_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX accounts_type_index ON public.accounts USING btree (type);


--
-- Name: client_users_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX client_users_email_index ON public.client_users USING btree (email);


--
-- Name: component_tags_name_project_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX component_tags_name_project_id_index ON public.component_tags USING btree (name, project_id);


--
-- Name: component_tags_project_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX component_tags_project_id_index ON public.component_tags USING btree (project_id);


--
-- Name: components_account_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX components_account_id_index ON public.components USING btree (account_id);


--
-- Name: components_module_name_project_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX components_module_name_project_id_index ON public.components USING btree (module_name, project_id);


--
-- Name: components_parent_component_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX components_parent_component_id_index ON public.components USING btree (parent_component_id);


--
-- Name: components_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX components_type_index ON public.components USING btree (type);


--
-- Name: content_admin_account_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX content_admin_account_id_index ON public.content_admin USING btree (account_id);


--
-- Name: content_admin_parse_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX content_admin_parse_status_index ON public.content_admin USING btree (parse_status);


--
-- Name: content_tags_content_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX content_tags_content_id_index ON public.content_tags USING btree (content_id);


--
-- Name: content_tags_content_id_tag_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX content_tags_content_id_tag_id_index ON public.content_tags USING btree (content_id, tag_id);


--
-- Name: content_tags_tag_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX content_tags_tag_id_index ON public.content_tags USING btree (tag_id);


--
-- Name: criteria_account_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX criteria_account_id_index ON public.criteria USING btree (account_id);


--
-- Name: criteria_position_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX criteria_position_index ON public.criteria USING btree ("position");


--
-- Name: criteria_project_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX criteria_project_id_index ON public.criteria USING btree (project_id);


--
-- Name: criteria_story_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX criteria_story_id_index ON public.criteria USING btree (story_id);


--
-- Name: dependencies_source_component_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX dependencies_source_component_id_index ON public.dependencies USING btree (source_component_id);


--
-- Name: dependencies_source_component_id_target_component_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX dependencies_source_component_id_target_component_id_index ON public.dependencies USING btree (source_component_id, target_component_id);


--
-- Name: dependencies_target_component_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX dependencies_target_component_id_index ON public.dependencies USING btree (target_component_id);


--
-- Name: file_edits_agent_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX file_edits_agent_id_index ON public.file_edits USING btree (agent_id) WHERE (agent_id IS NOT NULL);


--
-- Name: file_edits_external_session_id_file_path_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX file_edits_external_session_id_file_path_index ON public.file_edits USING btree (external_session_id, file_path);


--
-- Name: file_edits_external_session_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX file_edits_external_session_id_index ON public.file_edits USING btree (external_session_id);


--
-- Name: integrations_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX integrations_expires_at_index ON public.integrations USING btree (expires_at);


--
-- Name: integrations_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX integrations_user_id_index ON public.integrations USING btree (user_id);


--
-- Name: integrations_user_id_provider_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX integrations_user_id_provider_index ON public.integrations USING btree (user_id, provider);


--
-- Name: interaction_events_interaction_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interaction_events_interaction_id_index ON public.interaction_events USING btree (interaction_id);


--
-- Name: interaction_events_interaction_id_sent_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interaction_events_interaction_id_sent_at_index ON public.interaction_events USING btree (interaction_id, sent_at);


--
-- Name: interactions_session_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interactions_session_id_index ON public.interactions USING btree (session_id);


--
-- Name: interactions_session_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX interactions_session_id_inserted_at_index ON public.interactions USING btree (session_id, inserted_at);


--
-- Name: invitations_account_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invitations_account_id_index ON public.invitations USING btree (account_id);


--
-- Name: invitations_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invitations_email_index ON public.invitations USING btree (email);


--
-- Name: invitations_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invitations_expires_at_index ON public.invitations USING btree (expires_at);


--
-- Name: invitations_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX invitations_token_index ON public.invitations USING btree (token);


--
-- Name: members_account_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX members_account_id_index ON public.members USING btree (account_id);


--
-- Name: members_role_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX members_role_index ON public.members USING btree (role);


--
-- Name: members_user_id_account_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX members_user_id_account_id_index ON public.members USING btree (user_id, account_id);


--
-- Name: members_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX members_user_id_index ON public.members USING btree (user_id);


--
-- Name: oauth_access_grants_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX oauth_access_grants_token_index ON public.oauth_access_grants USING btree (token);


--
-- Name: oauth_access_tokens_refresh_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX oauth_access_tokens_refresh_token_index ON public.oauth_access_tokens USING btree (refresh_token);


--
-- Name: oauth_access_tokens_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX oauth_access_tokens_token_index ON public.oauth_access_tokens USING btree (token);


--
-- Name: oauth_applications_uid_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX oauth_applications_uid_index ON public.oauth_applications USING btree (uid);


--
-- Name: problems_file_path_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX problems_file_path_index ON public.problems USING btree (file_path);


--
-- Name: problems_project_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX problems_project_id_index ON public.problems USING btree (project_id);


--
-- Name: problems_severity_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX problems_severity_index ON public.problems USING btree (severity);


--
-- Name: problems_source_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX problems_source_type_index ON public.problems USING btree (source_type);


--
-- Name: projects_account_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX projects_account_id_index ON public.projects USING btree (account_id);


--
-- Name: projects_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX projects_user_id_index ON public.projects USING btree (user_id);


--
-- Name: push_subscriptions_endpoint_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX push_subscriptions_endpoint_index ON public.push_subscriptions USING btree (endpoint);


--
-- Name: push_subscriptions_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX push_subscriptions_user_id_index ON public.push_subscriptions USING btree (user_id);


--
-- Name: requirements_artifact_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX requirements_artifact_type_index ON public.requirements USING btree (artifact_type);


--
-- Name: requirements_component_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX requirements_component_id_index ON public.requirements USING btree (component_id);


--
-- Name: requirements_component_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX requirements_component_id_name_index ON public.requirements USING btree (component_id, name) WHERE (component_id IS NOT NULL);


--
-- Name: requirements_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX requirements_name_index ON public.requirements USING btree (name);


--
-- Name: requirements_project_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX requirements_project_id_index ON public.requirements USING btree (project_id);


--
-- Name: requirements_project_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX requirements_project_id_name_index ON public.requirements USING btree (project_id, name) WHERE (project_id IS NOT NULL);


--
-- Name: requirements_satisfied_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX requirements_satisfied_index ON public.requirements USING btree (satisfied);


--
-- Name: requirements_story_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX requirements_story_id_index ON public.requirements USING btree (story_id);


--
-- Name: requirements_story_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX requirements_story_id_name_index ON public.requirements USING btree (story_id, name) WHERE (story_id IS NOT NULL);


--
-- Name: rules_account_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rules_account_id_index ON public.rules USING btree (account_id);


--
-- Name: sessions_account_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sessions_account_id_index ON public.sessions USING btree (account_id);


--
-- Name: sessions_component_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sessions_component_id_index ON public.sessions USING btree (component_id);


--
-- Name: sessions_external_conversation_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sessions_external_conversation_id_index ON public.sessions USING btree (external_conversation_id);


--
-- Name: sessions_session_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sessions_session_id_index ON public.sessions USING btree (session_id);


--
-- Name: sessions_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sessions_user_id_index ON public.sessions USING btree (user_id);


--
-- Name: stories_account_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX stories_account_id_index ON public.stories USING btree (account_id);


--
-- Name: stories_component_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX stories_component_id_index ON public.stories USING btree (component_id);


--
-- Name: stories_current_version_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX stories_current_version_id_index ON public.stories USING btree (current_version_id);


--
-- Name: stories_first_version_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX stories_first_version_id_index ON public.stories USING btree (first_version_id);


--
-- Name: stories_locked_by_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX stories_locked_by_index ON public.stories USING btree (locked_by);


--
-- Name: stories_title_project_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX stories_title_project_id_index ON public.stories USING btree (title, project_id);


--
-- Name: story_tags_story_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX story_tags_story_id_index ON public.story_tags USING btree (story_id);


--
-- Name: story_tags_tag_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX story_tags_tag_id_index ON public.story_tags USING btree (tag_id);


--
-- Name: story_tags_tag_id_story_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX story_tags_tag_id_story_id_index ON public.story_tags USING btree (tag_id, story_id);


--
-- Name: tags_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX tags_slug_index ON public.tags USING btree (slug);


--
-- Name: unique_account_email_when_nulls; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX unique_account_email_when_nulls ON public.invitations USING btree (email, account_id) WHERE ((accepted_at IS NULL) AND (cancelled_at IS NULL));


--
-- Name: user_preferences_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_preferences_user_id_index ON public.user_preferences USING btree (user_id);


--
-- Name: users_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_email_index ON public.users USING btree (email);


--
-- Name: users_tokens_context_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_tokens_context_token_index ON public.users_tokens USING btree (context, token);


--
-- Name: users_tokens_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_tokens_user_id_index ON public.users_tokens USING btree (user_id);


--
-- Name: versions_item_id_item_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX versions_item_id_item_type_index ON public.versions USING btree (item_id, item_type);


--
-- Name: versions_originator_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX versions_originator_id_index ON public.versions USING btree (originator_id);


--
-- Name: component_tags component_tags_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_tags
    ADD CONSTRAINT component_tags_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: components components_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.components
    ADD CONSTRAINT components_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE CASCADE;


--
-- Name: components components_parent_component_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.components
    ADD CONSTRAINT components_parent_component_id_fkey FOREIGN KEY (parent_component_id) REFERENCES public.components(id) ON DELETE SET NULL;


--
-- Name: components components_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.components
    ADD CONSTRAINT components_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: content_admin content_admin_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_admin
    ADD CONSTRAINT content_admin_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE CASCADE;


--
-- Name: content_admin content_admin_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_admin
    ADD CONSTRAINT content_admin_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: content_tags content_tags_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_tags
    ADD CONSTRAINT content_tags_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.tags(id) ON DELETE CASCADE;


--
-- Name: criteria criteria_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.criteria
    ADD CONSTRAINT criteria_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE CASCADE;


--
-- Name: criteria criteria_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.criteria
    ADD CONSTRAINT criteria_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: criteria criteria_story_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.criteria
    ADD CONSTRAINT criteria_story_id_fkey FOREIGN KEY (story_id) REFERENCES public.stories(id) ON DELETE CASCADE;


--
-- Name: dependencies dependencies_source_component_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dependencies
    ADD CONSTRAINT dependencies_source_component_id_fkey FOREIGN KEY (source_component_id) REFERENCES public.components(id) ON DELETE CASCADE;


--
-- Name: dependencies dependencies_target_component_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dependencies
    ADD CONSTRAINT dependencies_target_component_id_fkey FOREIGN KEY (target_component_id) REFERENCES public.components(id) ON DELETE CASCADE;


--
-- Name: integrations integrations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integrations
    ADD CONSTRAINT integrations_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: interaction_events interaction_events_interaction_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interaction_events
    ADD CONSTRAINT interaction_events_interaction_id_fkey FOREIGN KEY (interaction_id) REFERENCES public.interactions(id) ON DELETE CASCADE;


--
-- Name: interactions interactions_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.interactions
    ADD CONSTRAINT interactions_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.sessions(id) ON DELETE CASCADE;


--
-- Name: invitations invitations_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitations
    ADD CONSTRAINT invitations_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE CASCADE;


--
-- Name: invitations invitations_invited_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitations
    ADD CONSTRAINT invitations_invited_by_id_fkey FOREIGN KEY (invited_by_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: members members_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.members
    ADD CONSTRAINT members_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE CASCADE;


--
-- Name: members members_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.members
    ADD CONSTRAINT members_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: oauth_access_grants oauth_access_grants_application_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_access_grants
    ADD CONSTRAINT oauth_access_grants_application_id_fkey FOREIGN KEY (application_id) REFERENCES public.oauth_applications(id);


--
-- Name: oauth_access_grants oauth_access_grants_resource_owner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_access_grants
    ADD CONSTRAINT oauth_access_grants_resource_owner_id_fkey FOREIGN KEY (resource_owner_id) REFERENCES public.users(id);


--
-- Name: oauth_access_tokens oauth_access_tokens_application_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_access_tokens
    ADD CONSTRAINT oauth_access_tokens_application_id_fkey FOREIGN KEY (application_id) REFERENCES public.oauth_applications(id);


--
-- Name: oauth_access_tokens oauth_access_tokens_resource_owner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_access_tokens
    ADD CONSTRAINT oauth_access_tokens_resource_owner_id_fkey FOREIGN KEY (resource_owner_id) REFERENCES public.users(id);


--
-- Name: oauth_applications oauth_applications_owner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oauth_applications
    ADD CONSTRAINT oauth_applications_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: problems problems_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.problems
    ADD CONSTRAINT problems_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: projects projects_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: projects projects_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: push_subscriptions push_subscriptions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.push_subscriptions
    ADD CONSTRAINT push_subscriptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: requirements requirements_component_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.requirements
    ADD CONSTRAINT requirements_component_id_fkey FOREIGN KEY (component_id) REFERENCES public.components(id) ON DELETE CASCADE;


--
-- Name: rules rules_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rules
    ADD CONSTRAINT rules_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: sessions sessions_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: sessions sessions_component_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_component_id_fkey FOREIGN KEY (component_id) REFERENCES public.components(id);


--
-- Name: sessions sessions_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id);


--
-- Name: sessions sessions_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.sessions(id) ON DELETE CASCADE;


--
-- Name: sessions sessions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: stories stories_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stories
    ADD CONSTRAINT stories_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE CASCADE;


--
-- Name: stories stories_current_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stories
    ADD CONSTRAINT stories_current_version_id_fkey FOREIGN KEY (current_version_id) REFERENCES public.versions(id);


--
-- Name: stories stories_first_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stories
    ADD CONSTRAINT stories_first_version_id_fkey FOREIGN KEY (first_version_id) REFERENCES public.versions(id);


--
-- Name: stories stories_locked_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stories
    ADD CONSTRAINT stories_locked_by_fkey FOREIGN KEY (locked_by) REFERENCES public.users(id);


--
-- Name: stories stories_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stories
    ADD CONSTRAINT stories_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: story_tags story_tags_story_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.story_tags
    ADD CONSTRAINT story_tags_story_id_fkey FOREIGN KEY (story_id) REFERENCES public.stories(id) ON DELETE CASCADE;


--
-- Name: story_tags story_tags_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.story_tags
    ADD CONSTRAINT story_tags_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.component_tags(id) ON DELETE CASCADE;


--
-- Name: user_preferences user_preferences_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_preferences
    ADD CONSTRAINT user_preferences_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: users_tokens users_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users_tokens
    ADD CONSTRAINT users_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: versions versions_originator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.versions
    ADD CONSTRAINT versions_originator_id_fkey FOREIGN KEY (originator_id) REFERENCES public.users(id);


--
-- PostgreSQL database dump complete
--

INSERT INTO public."schema_migrations" (version) VALUES (20250714190744);
INSERT INTO public."schema_migrations" (version) VALUES (20250714190755);
INSERT INTO public."schema_migrations" (version) VALUES (20250714190803);
INSERT INTO public."schema_migrations" (version) VALUES (20250715202726);
INSERT INTO public."schema_migrations" (version) VALUES (20250716024710);
INSERT INTO public."schema_migrations" (version) VALUES (20250718015711);
INSERT INTO public."schema_migrations" (version) VALUES (20250718022705);
INSERT INTO public."schema_migrations" (version) VALUES (20250718123333);
INSERT INTO public."schema_migrations" (version) VALUES (20250718124829);
INSERT INTO public."schema_migrations" (version) VALUES (20250718124830);
INSERT INTO public."schema_migrations" (version) VALUES (20250718144547);
INSERT INTO public."schema_migrations" (version) VALUES (20250730035612);
INSERT INTO public."schema_migrations" (version) VALUES (20250730035639);
INSERT INTO public."schema_migrations" (version) VALUES (20250801021012);
INSERT INTO public."schema_migrations" (version) VALUES (20250802150626);
INSERT INTO public."schema_migrations" (version) VALUES (20250802192629);
INSERT INTO public."schema_migrations" (version) VALUES (20250802210606);
INSERT INTO public."schema_migrations" (version) VALUES (20250804131540);
INSERT INTO public."schema_migrations" (version) VALUES (20250804210626);
INSERT INTO public."schema_migrations" (version) VALUES (20250819205953);
INSERT INTO public."schema_migrations" (version) VALUES (20250822171410);
INSERT INTO public."schema_migrations" (version) VALUES (20250822235417);
INSERT INTO public."schema_migrations" (version) VALUES (20250902014036);
INSERT INTO public."schema_migrations" (version) VALUES (20250903191543);
INSERT INTO public."schema_migrations" (version) VALUES (20251003215323);
INSERT INTO public."schema_migrations" (version) VALUES (20251004170751);
INSERT INTO public."schema_migrations" (version) VALUES (20251004170849);
INSERT INTO public."schema_migrations" (version) VALUES (20251005031255);
INSERT INTO public."schema_migrations" (version) VALUES (20251006030747);
INSERT INTO public."schema_migrations" (version) VALUES (20251006031833);
INSERT INTO public."schema_migrations" (version) VALUES (20251007015638);
INSERT INTO public."schema_migrations" (version) VALUES (20251008020945);
INSERT INTO public."schema_migrations" (version) VALUES (20251009133352);
INSERT INTO public."schema_migrations" (version) VALUES (20251009133752);
INSERT INTO public."schema_migrations" (version) VALUES (20251012024734);
INSERT INTO public."schema_migrations" (version) VALUES (20251013015240);
INSERT INTO public."schema_migrations" (version) VALUES (20251013015436);
INSERT INTO public."schema_migrations" (version) VALUES (20251013023511);
INSERT INTO public."schema_migrations" (version) VALUES (20251013024430);
INSERT INTO public."schema_migrations" (version) VALUES (20251015185756);
INSERT INTO public."schema_migrations" (version) VALUES (20251016040449);
INSERT INTO public."schema_migrations" (version) VALUES (20251028133426);
INSERT INTO public."schema_migrations" (version) VALUES (20251028211953);
INSERT INTO public."schema_migrations" (version) VALUES (20251029015240);
INSERT INTO public."schema_migrations" (version) VALUES (20251029024734);
INSERT INTO public."schema_migrations" (version) VALUES (20251108052225);
INSERT INTO public."schema_migrations" (version) VALUES (20251112213902);
INSERT INTO public."schema_migrations" (version) VALUES (20251127154600);
INSERT INTO public."schema_migrations" (version) VALUES (20251127154601);
INSERT INTO public."schema_migrations" (version) VALUES (20251127155810);
INSERT INTO public."schema_migrations" (version) VALUES (20251127160405);
INSERT INTO public."schema_migrations" (version) VALUES (20251127160601);
INSERT INTO public."schema_migrations" (version) VALUES (20251127161439);
INSERT INTO public."schema_migrations" (version) VALUES (20251127185636);
INSERT INTO public."schema_migrations" (version) VALUES (20251128000000);
INSERT INTO public."schema_migrations" (version) VALUES (20251128154100);
INSERT INTO public."schema_migrations" (version) VALUES (20251129201725);
INSERT INTO public."schema_migrations" (version) VALUES (20251129210700);
INSERT INTO public."schema_migrations" (version) VALUES (20251129235959);
INSERT INTO public."schema_migrations" (version) VALUES (20251206033422);
INSERT INTO public."schema_migrations" (version) VALUES (20251215151848);
INSERT INTO public."schema_migrations" (version) VALUES (20251215164313);
INSERT INTO public."schema_migrations" (version) VALUES (20260104044014);
INSERT INTO public."schema_migrations" (version) VALUES (20260106140047);
INSERT INTO public."schema_migrations" (version) VALUES (20260113171440);
INSERT INTO public."schema_migrations" (version) VALUES (20260118122845);
INSERT INTO public."schema_migrations" (version) VALUES (20260119200000);
INSERT INTO public."schema_migrations" (version) VALUES (20260120120000);
INSERT INTO public."schema_migrations" (version) VALUES (20260122171336);
INSERT INTO public."schema_migrations" (version) VALUES (20260123095216);
INSERT INTO public."schema_migrations" (version) VALUES (20260126153450);
INSERT INTO public."schema_migrations" (version) VALUES (20260128213231);
INSERT INTO public."schema_migrations" (version) VALUES (20260128213232);
INSERT INTO public."schema_migrations" (version) VALUES (20260130122351);
INSERT INTO public."schema_migrations" (version) VALUES (20260201031557);
INSERT INTO public."schema_migrations" (version) VALUES (20260201191953);
INSERT INTO public."schema_migrations" (version) VALUES (20260201200000);
INSERT INTO public."schema_migrations" (version) VALUES (20260206224921);
INSERT INTO public."schema_migrations" (version) VALUES (20260208134835);
INSERT INTO public."schema_migrations" (version) VALUES (20260223232854);
INSERT INTO public."schema_migrations" (version) VALUES (20260226183436);
INSERT INTO public."schema_migrations" (version) VALUES (20260227200238);
