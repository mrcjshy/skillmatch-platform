


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


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";





SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."bookings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "job_id" "uuid" NOT NULL,
    "worker_id" "uuid" NOT NULL,
    "client_id" "uuid" NOT NULL,
    "status" character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    "payment_method" character varying(20),
    "payment_status" character varying(20) DEFAULT 'pending'::character varying,
    "paymongo_ref" character varying(100),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "completed_at" timestamp with time zone,
    CONSTRAINT "bookings_payment_method_check" CHECK ((("payment_method")::"text" = ANY ((ARRAY['gcash'::character varying, 'maya'::character varying, 'cod'::character varying])::"text"[]))),
    CONSTRAINT "bookings_payment_status_check" CHECK ((("payment_status")::"text" = ANY ((ARRAY['pending'::character varying, 'paid'::character varying, 'refunded'::character varying])::"text"[]))),
    CONSTRAINT "bookings_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['pending'::character varying, 'confirmed'::character varying, 'completed'::character varying, 'cancelled'::character varying, 'no_show'::character varying])::"text"[])))
);


ALTER TABLE "public"."bookings" OWNER TO "postgres";


COMMENT ON TABLE "public"."bookings" IS 'Core transaction: links matched workers to client job postings';



COMMENT ON COLUMN "public"."bookings"."status" IS 'Lifecycle: pending → confirmed → completed (or cancelled/no_show)';



COMMENT ON COLUMN "public"."bookings"."paymongo_ref" IS 'PayMongo payment reference ID for transaction verification';



CREATE TABLE IF NOT EXISTS "public"."job_postings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "client_id" "uuid" NOT NULL,
    "title" character varying(150) NOT NULL,
    "description" "text",
    "address" "text",
    "barangay" character varying(100),
    "city" character varying(100),
    "scheduled_at" timestamp with time zone,
    "status" character varying(20) DEFAULT 'open'::character varying,
    "budget" numeric(10,2),
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "job_postings_budget_check" CHECK (("budget" >= (0)::numeric)),
    CONSTRAINT "job_postings_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['open'::character varying, 'matched'::character varying, 'completed'::character varying, 'cancelled'::character varying])::"text"[])))
);


ALTER TABLE "public"."job_postings" OWNER TO "postgres";


COMMENT ON TABLE "public"."job_postings" IS 'Client-posted job requests for worker matching';



COMMENT ON COLUMN "public"."job_postings"."status" IS 'Job lifecycle: open → matched → completed (or cancelled)';



COMMENT ON COLUMN "public"."job_postings"."budget" IS 'Job budget in PHP. DECIMAL used for exact monetary values.';



CREATE TABLE IF NOT EXISTS "public"."job_skills" (
    "job_id" "uuid" NOT NULL,
    "skill_id" "uuid" NOT NULL
);


ALTER TABLE "public"."job_skills" OWNER TO "postgres";


COMMENT ON TABLE "public"."job_skills" IS 'Junction table: Maps job postings to their required skills for matching';



CREATE TABLE IF NOT EXISTS "public"."messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "booking_id" "uuid" NOT NULL,
    "sender_id" "uuid" NOT NULL,
    "content" "text" NOT NULL,
    "is_read" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "type" character varying(50) NOT NULL,
    "message" "text" NOT NULL,
    "is_read" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "notifications_type_check" CHECK ((("type")::"text" = ANY ((ARRAY['booking_request'::character varying, 'booking_confirmed'::character varying, 'booking_cancelled'::character varying, 'booking_completed'::character varying, 'no_show_strike'::character varying, 'account_suspended'::character varying, 'payment_received'::character varying])::"text"[])))
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


COMMENT ON TABLE "public"."notifications" IS 'In-app notifications triggered by system events';



COMMENT ON COLUMN "public"."notifications"."type" IS 'Category used by React to render different notification styles';



COMMENT ON COLUMN "public"."notifications"."is_read" IS 'false = unread (shows badge). Updated to true when user views it.';



CREATE TABLE IF NOT EXISTS "public"."portfolio_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "worker_id" "uuid" NOT NULL,
    "title" character varying(150) NOT NULL,
    "description" "text",
    "image_url" "text",
    "project_scale" character varying(20) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "portfolio_items_project_scale_check" CHECK ((("project_scale")::"text" = ANY ((ARRAY['small'::character varying, 'medium'::character varying, 'large'::character varying])::"text"[])))
);


ALTER TABLE "public"."portfolio_items" OWNER TO "postgres";


COMMENT ON TABLE "public"."portfolio_items" IS 'Worker portfolio showcasing past projects with scale indicators';



COMMENT ON COLUMN "public"."portfolio_items"."project_scale" IS 'Used for badge_level calculation: small, medium, or large projects';



CREATE TABLE IF NOT EXISTS "public"."ratings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "booking_id" "uuid" NOT NULL,
    "rated_by" "uuid" NOT NULL,
    "rated_user" "uuid" NOT NULL,
    "score" integer NOT NULL,
    "comment" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "ratings_score_check" CHECK ((("score" >= 1) AND ("score" <= 5)))
);


ALTER TABLE "public"."ratings" OWNER TO "postgres";


COMMENT ON TABLE "public"."ratings" IS 'Post-booking ratings submitted between workers and clients';



COMMENT ON COLUMN "public"."ratings"."rated_by" IS 'The user submitting the rating';



COMMENT ON COLUMN "public"."ratings"."rated_user" IS 'The user receiving the rating';



COMMENT ON COLUMN "public"."ratings"."score" IS 'Whole number 1-5. Average stored in worker_profiles.rating_avg';



CREATE TABLE IF NOT EXISTS "public"."skills" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "skill_name" character varying(100) NOT NULL,
    "category" character varying(50)
);


ALTER TABLE "public"."skills" OWNER TO "postgres";


COMMENT ON TABLE "public"."skills" IS 'Master list of skills for worker profiling and job matching';



CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "full_name" "text" NOT NULL,
    "phone" "text" NOT NULL,
    "role" "text" NOT NULL,
    "barangay" "text" NOT NULL,
    "city" "text" NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "users_role_check" CHECK (("role" = ANY (ARRAY['worker'::"text", 'client'::"text", 'administrator'::"text"])))
);


ALTER TABLE "public"."users" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."worker_profiles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "bio" "text",
    "badge_level" character varying(20),
    "availability_status" character varying(20) DEFAULT 'available'::character varying,
    "is_verified" boolean DEFAULT false,
    "verified_by" "uuid",
    "rating_avg" double precision DEFAULT 0,
    "strike_count" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "worker_profiles_availability_status_check" CHECK ((("availability_status")::"text" = ANY ((ARRAY['available'::character varying, 'busy'::character varying, 'offline'::character varying])::"text"[]))),
    CONSTRAINT "worker_profiles_badge_level_check" CHECK ((("badge_level")::"text" = ANY ((ARRAY['none'::character varying, 'small'::character varying, 'medium'::character varying, 'large'::character varying])::"text"[]))),
    CONSTRAINT "worker_profiles_rating_avg_check" CHECK ((("rating_avg" >= (0)::double precision) AND ("rating_avg" <= (5)::double precision))),
    CONSTRAINT "worker_profiles_strike_count_check" CHECK ((("strike_count" >= 0) AND ("strike_count" <= 3)))
);


ALTER TABLE "public"."worker_profiles" OWNER TO "postgres";


COMMENT ON TABLE "public"."worker_profiles" IS 'Extended profile information for users with worker role';



COMMENT ON COLUMN "public"."worker_profiles"."strike_count" IS 'No-show counter. Account suspended at 3 strikes.';



CREATE TABLE IF NOT EXISTS "public"."worker_skills" (
    "worker_id" "uuid" NOT NULL,
    "skill_id" "uuid" NOT NULL,
    "proficiency_level" character varying(20) DEFAULT 'beginner'::character varying,
    CONSTRAINT "worker_skills_proficiency_level_check" CHECK ((("proficiency_level")::"text" = ANY ((ARRAY['beginner'::character varying, 'intermediate'::character varying, 'expert'::character varying])::"text"[])))
);


ALTER TABLE "public"."worker_skills" OWNER TO "postgres";


COMMENT ON TABLE "public"."worker_skills" IS 'Junction table: Maps workers to their skills with proficiency levels';



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."job_postings"
    ADD CONSTRAINT "job_postings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."job_skills"
    ADD CONSTRAINT "job_skills_pkey" PRIMARY KEY ("job_id", "skill_id");



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."portfolio_items"
    ADD CONSTRAINT "portfolio_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_booking_id_rated_by_key" UNIQUE ("booking_id", "rated_by");



ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."skills"
    ADD CONSTRAINT "skills_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."skills"
    ADD CONSTRAINT "skills_skill_name_key" UNIQUE ("skill_name");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."worker_profiles"
    ADD CONSTRAINT "worker_profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."worker_profiles"
    ADD CONSTRAINT "worker_profiles_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."worker_skills"
    ADD CONSTRAINT "worker_skills_pkey" PRIMARY KEY ("worker_id", "skill_id");



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."job_postings"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_worker_id_fkey" FOREIGN KEY ("worker_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_postings"
    ADD CONSTRAINT "job_postings_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_skills"
    ADD CONSTRAINT "job_skills_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."job_postings"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."job_skills"
    ADD CONSTRAINT "job_skills_skill_id_fkey" FOREIGN KEY ("skill_id") REFERENCES "public"."skills"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."bookings"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."messages"
    ADD CONSTRAINT "messages_sender_id_fkey" FOREIGN KEY ("sender_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."portfolio_items"
    ADD CONSTRAINT "portfolio_items_worker_id_fkey" FOREIGN KEY ("worker_id") REFERENCES "public"."worker_profiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."bookings"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_rated_by_fkey" FOREIGN KEY ("rated_by") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ratings"
    ADD CONSTRAINT "ratings_rated_user_fkey" FOREIGN KEY ("rated_user") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."worker_profiles"
    ADD CONSTRAINT "worker_profiles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."worker_profiles"
    ADD CONSTRAINT "worker_profiles_verified_by_fkey" FOREIGN KEY ("verified_by") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."worker_skills"
    ADD CONSTRAINT "worker_skills_skill_id_fkey" FOREIGN KEY ("skill_id") REFERENCES "public"."skills"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."worker_skills"
    ADD CONSTRAINT "worker_skills_worker_id_fkey" FOREIGN KEY ("worker_id") REFERENCES "public"."worker_profiles"("id") ON DELETE CASCADE;



CREATE POLICY "Anyone authenticated can read job skills" ON "public"."job_skills" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Anyone authenticated can read open jobs" ON "public"."job_postings" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Anyone authenticated can read portfolio items" ON "public"."portfolio_items" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Anyone authenticated can read ratings" ON "public"."ratings" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Anyone authenticated can read skills" ON "public"."skills" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Anyone authenticated can read worker profiles" ON "public"."worker_profiles" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Anyone authenticated can read worker skills" ON "public"."worker_skills" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can insert ratings" ON "public"."ratings" FOR INSERT TO "authenticated" WITH CHECK (("rated_by" = "auth"."uid"()));



CREATE POLICY "Clients can delete their own jobs" ON "public"."job_postings" FOR DELETE TO "authenticated" USING (("client_id" = "auth"."uid"()));



CREATE POLICY "Clients can insert their own jobs" ON "public"."job_postings" FOR INSERT TO "authenticated" WITH CHECK (("client_id" = "auth"."uid"()));



CREATE POLICY "Clients can manage their job skills" ON "public"."job_skills" TO "authenticated" USING (("job_id" IN ( SELECT "job_postings"."id"
   FROM "public"."job_postings"
  WHERE ("job_postings"."client_id" = "auth"."uid"()))));



CREATE POLICY "Clients can update their own jobs" ON "public"."job_postings" FOR UPDATE TO "authenticated" USING (("client_id" = "auth"."uid"()));



CREATE POLICY "System can insert bookings" ON "public"."bookings" FOR INSERT TO "authenticated" WITH CHECK (("client_id" = "auth"."uid"()));



CREATE POLICY "System can insert notifications" ON "public"."notifications" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Users can mark their own notifications as read" ON "public"."notifications" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can read their own notifications" ON "public"."notifications" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can send messages in their bookings" ON "public"."messages" FOR INSERT WITH CHECK ((("auth"."uid"() = "sender_id") AND ("auth"."uid"() IN ( SELECT "bookings"."worker_id"
   FROM "public"."bookings"
  WHERE ("bookings"."id" = "messages"."booking_id")
UNION
 SELECT "bookings"."client_id"
   FROM "public"."bookings"
  WHERE ("bookings"."id" = "messages"."booking_id")))));



CREATE POLICY "Users can view messages in their bookings" ON "public"."messages" FOR SELECT USING (("auth"."uid"() IN ( SELECT "bookings"."worker_id"
   FROM "public"."bookings"
  WHERE ("bookings"."id" = "messages"."booking_id")
UNION
 SELECT "bookings"."client_id"
   FROM "public"."bookings"
  WHERE ("bookings"."id" = "messages"."booking_id"))));



CREATE POLICY "Workers and clients can update their own bookings" ON "public"."bookings" FOR UPDATE TO "authenticated" USING ((("worker_id" = "auth"."uid"()) OR ("client_id" = "auth"."uid"())));



CREATE POLICY "Workers and clients can view their own bookings" ON "public"."bookings" FOR SELECT TO "authenticated" USING ((("worker_id" = "auth"."uid"()) OR ("client_id" = "auth"."uid"())));



CREATE POLICY "Workers can insert their own profile" ON "public"."worker_profiles" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Workers can manage their own portfolio" ON "public"."portfolio_items" TO "authenticated" USING (("worker_id" IN ( SELECT "worker_profiles"."id"
   FROM "public"."worker_profiles"
  WHERE ("worker_profiles"."user_id" = "auth"."uid"()))));



CREATE POLICY "Workers can manage their own skills" ON "public"."worker_skills" TO "authenticated" USING (("worker_id" IN ( SELECT "worker_profiles"."id"
   FROM "public"."worker_profiles"
  WHERE ("worker_profiles"."user_id" = "auth"."uid"()))));



CREATE POLICY "Workers can update their own profile" ON "public"."worker_profiles" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "allow_insert_own_profile" ON "public"."users" FOR INSERT WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "allow_read_own_profile" ON "public"."users" FOR SELECT USING (("auth"."uid"() = "id"));



CREATE POLICY "allow_update_own_profile" ON "public"."users" FOR UPDATE USING (("auth"."uid"() = "id")) WITH CHECK (("auth"."uid"() = "id"));



ALTER TABLE "public"."bookings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."job_postings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."job_skills" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."portfolio_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ratings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."skills" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."worker_profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."worker_skills" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";





































































































































































GRANT ALL ON TABLE "public"."bookings" TO "anon";
GRANT ALL ON TABLE "public"."bookings" TO "authenticated";
GRANT ALL ON TABLE "public"."bookings" TO "service_role";



GRANT ALL ON TABLE "public"."job_postings" TO "anon";
GRANT ALL ON TABLE "public"."job_postings" TO "authenticated";
GRANT ALL ON TABLE "public"."job_postings" TO "service_role";



GRANT ALL ON TABLE "public"."job_skills" TO "anon";
GRANT ALL ON TABLE "public"."job_skills" TO "authenticated";
GRANT ALL ON TABLE "public"."job_skills" TO "service_role";



GRANT ALL ON TABLE "public"."messages" TO "anon";
GRANT ALL ON TABLE "public"."messages" TO "authenticated";
GRANT ALL ON TABLE "public"."messages" TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT ALL ON TABLE "public"."portfolio_items" TO "anon";
GRANT ALL ON TABLE "public"."portfolio_items" TO "authenticated";
GRANT ALL ON TABLE "public"."portfolio_items" TO "service_role";



GRANT ALL ON TABLE "public"."ratings" TO "anon";
GRANT ALL ON TABLE "public"."ratings" TO "authenticated";
GRANT ALL ON TABLE "public"."ratings" TO "service_role";



GRANT ALL ON TABLE "public"."skills" TO "anon";
GRANT ALL ON TABLE "public"."skills" TO "authenticated";
GRANT ALL ON TABLE "public"."skills" TO "service_role";



GRANT ALL ON TABLE "public"."users" TO "anon";
GRANT ALL ON TABLE "public"."users" TO "authenticated";
GRANT ALL ON TABLE "public"."users" TO "service_role";



GRANT ALL ON TABLE "public"."worker_profiles" TO "anon";
GRANT ALL ON TABLE "public"."worker_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."worker_profiles" TO "service_role";



GRANT ALL ON TABLE "public"."worker_skills" TO "anon";
GRANT ALL ON TABLE "public"."worker_skills" TO "authenticated";
GRANT ALL ON TABLE "public"."worker_skills" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































drop extension if exists "pg_net";

alter table "public"."bookings" drop constraint "bookings_payment_method_check";

alter table "public"."bookings" drop constraint "bookings_payment_status_check";

alter table "public"."bookings" drop constraint "bookings_status_check";

alter table "public"."job_postings" drop constraint "job_postings_status_check";

alter table "public"."notifications" drop constraint "notifications_type_check";

alter table "public"."portfolio_items" drop constraint "portfolio_items_project_scale_check";

alter table "public"."worker_profiles" drop constraint "worker_profiles_availability_status_check";

alter table "public"."worker_profiles" drop constraint "worker_profiles_badge_level_check";

alter table "public"."worker_skills" drop constraint "worker_skills_proficiency_level_check";

alter table "public"."bookings" add constraint "bookings_payment_method_check" CHECK (((payment_method)::text = ANY ((ARRAY['gcash'::character varying, 'maya'::character varying, 'cod'::character varying])::text[]))) not valid;

alter table "public"."bookings" validate constraint "bookings_payment_method_check";

alter table "public"."bookings" add constraint "bookings_payment_status_check" CHECK (((payment_status)::text = ANY ((ARRAY['pending'::character varying, 'paid'::character varying, 'refunded'::character varying])::text[]))) not valid;

alter table "public"."bookings" validate constraint "bookings_payment_status_check";

alter table "public"."bookings" add constraint "bookings_status_check" CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'confirmed'::character varying, 'completed'::character varying, 'cancelled'::character varying, 'no_show'::character varying])::text[]))) not valid;

alter table "public"."bookings" validate constraint "bookings_status_check";

alter table "public"."job_postings" add constraint "job_postings_status_check" CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'matched'::character varying, 'completed'::character varying, 'cancelled'::character varying])::text[]))) not valid;

alter table "public"."job_postings" validate constraint "job_postings_status_check";

alter table "public"."notifications" add constraint "notifications_type_check" CHECK (((type)::text = ANY ((ARRAY['booking_request'::character varying, 'booking_confirmed'::character varying, 'booking_cancelled'::character varying, 'booking_completed'::character varying, 'no_show_strike'::character varying, 'account_suspended'::character varying, 'payment_received'::character varying])::text[]))) not valid;

alter table "public"."notifications" validate constraint "notifications_type_check";

alter table "public"."portfolio_items" add constraint "portfolio_items_project_scale_check" CHECK (((project_scale)::text = ANY ((ARRAY['small'::character varying, 'medium'::character varying, 'large'::character varying])::text[]))) not valid;

alter table "public"."portfolio_items" validate constraint "portfolio_items_project_scale_check";

alter table "public"."worker_profiles" add constraint "worker_profiles_availability_status_check" CHECK (((availability_status)::text = ANY ((ARRAY['available'::character varying, 'busy'::character varying, 'offline'::character varying])::text[]))) not valid;

alter table "public"."worker_profiles" validate constraint "worker_profiles_availability_status_check";

alter table "public"."worker_profiles" add constraint "worker_profiles_badge_level_check" CHECK (((badge_level)::text = ANY ((ARRAY['none'::character varying, 'small'::character varying, 'medium'::character varying, 'large'::character varying])::text[]))) not valid;

alter table "public"."worker_profiles" validate constraint "worker_profiles_badge_level_check";

alter table "public"."worker_skills" add constraint "worker_skills_proficiency_level_check" CHECK (((proficiency_level)::text = ANY ((ARRAY['beginner'::character varying, 'intermediate'::character varying, 'expert'::character varying])::text[]))) not valid;

alter table "public"."worker_skills" validate constraint "worker_skills_proficiency_level_check";


