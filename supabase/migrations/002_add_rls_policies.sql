-- ============================================
-- RLS POLICIES FOR ALL TABLES
-- ============================================

-- ----------------------------
-- SKILLS (master list)
-- ----------------------------
CREATE POLICY "Anyone authenticated can read skills"
ON skills FOR SELECT
TO authenticated
USING (true);

-- ----------------------------
-- WORKER PROFILES
-- ----------------------------
CREATE POLICY "Anyone authenticated can read worker profiles"
ON worker_profiles FOR SELECT
TO authenticated
USING (true);

CREATE POLICY "Workers can insert their own profile"
ON worker_profiles FOR INSERT
TO authenticated
WITH CHECK (user_id = auth.uid());

CREATE POLICY "Workers can update their own profile"
ON worker_profiles FOR UPDATE
TO authenticated
USING (user_id = auth.uid());

-- ----------------------------
-- WORKER SKILLS
-- ----------------------------
CREATE POLICY "Anyone authenticated can read worker skills"
ON worker_skills FOR SELECT
TO authenticated
USING (true);

CREATE POLICY "Workers can manage their own skills"
ON worker_skills FOR ALL
TO authenticated
USING (
    worker_id IN (
        SELECT id FROM worker_profiles WHERE user_id = auth.uid()
    )
);

-- ----------------------------
-- PORTFOLIO ITEMS
-- ----------------------------
CREATE POLICY "Anyone authenticated can read portfolio items"
ON portfolio_items FOR SELECT
TO authenticated
USING (true);

CREATE POLICY "Workers can manage their own portfolio"
ON portfolio_items FOR ALL
TO authenticated
USING (
    worker_id IN (
        SELECT id FROM worker_profiles WHERE user_id = auth.uid()
    )
);

-- ----------------------------
-- JOB POSTINGS
-- ----------------------------
CREATE POLICY "Anyone authenticated can read open jobs"
ON job_postings FOR SELECT
TO authenticated
USING (true);

CREATE POLICY "Clients can insert their own jobs"
ON job_postings FOR INSERT
TO authenticated
WITH CHECK (client_id = auth.uid());

CREATE POLICY "Clients can update their own jobs"
ON job_postings FOR UPDATE
TO authenticated
USING (client_id = auth.uid());

CREATE POLICY "Clients can delete their own jobs"
ON job_postings FOR DELETE
TO authenticated
USING (client_id = auth.uid());

-- ----------------------------
-- JOB SKILLS
-- ----------------------------
CREATE POLICY "Anyone authenticated can read job skills"
ON job_skills FOR SELECT
TO authenticated
USING (true);

CREATE POLICY "Clients can manage their job skills"
ON job_skills FOR ALL
TO authenticated
USING (
    job_id IN (
        SELECT id FROM job_postings WHERE client_id = auth.uid()
    )
);

-- ----------------------------
-- BOOKINGS
-- ----------------------------
CREATE POLICY "Workers and clients can view their own bookings"
ON bookings FOR SELECT
TO authenticated
USING (
    worker_id = auth.uid() OR client_id = auth.uid()
);

CREATE POLICY "System can insert bookings"
ON bookings FOR INSERT
TO authenticated
WITH CHECK (
    client_id = auth.uid()
);

CREATE POLICY "Workers and clients can update their own bookings"
ON bookings FOR UPDATE
TO authenticated
USING (
    worker_id = auth.uid() OR client_id = auth.uid()
);

-- ----------------------------
-- NOTIFICATIONS
-- ----------------------------
CREATE POLICY "Users can read their own notifications"
ON notifications FOR SELECT
TO authenticated
USING (user_id = auth.uid());

CREATE POLICY "System can insert notifications"
ON notifications FOR INSERT
TO authenticated
WITH CHECK (true);

CREATE POLICY "Users can mark their own notifications as read"
ON notifications FOR UPDATE
TO authenticated
USING (user_id = auth.uid());

-- ----------------------------
-- RATINGS
-- ----------------------------
CREATE POLICY "Anyone authenticated can read ratings"
ON ratings FOR SELECT
TO authenticated
USING (true);

CREATE POLICY "Authenticated users can insert ratings"
ON ratings FOR INSERT
TO authenticated
WITH CHECK (rated_by = auth.uid());
