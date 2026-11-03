# frozen_string_literal: true

# ---------------------------------------------------------------------------
# TiDB compatibility patch
# ---------------------------------------------------------------------------
# TiDB (unlike MySQL and PostgreSQL) does not support subqueries inside a
# JOIN's ON clause:
#
#   Mysql2::Error: ON condition doesn't support subqueries yet
#
# Redmine's TimeEntry.left_join_issue scope injects Issue.visible_condition
# into the ON clause of a LEFT OUTER JOIN on `issues`, and that condition
# contains two subqueries:
#
#   1. EXISTS (SELECT 1 FROM enabled_modules WHERE ...)
#   2. projects.id NOT IN (SELECT project_id FROM members WHERE ...)
#
# This breaks every request to /projects/:id/time_entries (TimelogController)
# with a 500 "Internal error".
#
# We cannot move the condition to WHERE: the join is a LEFT OUTER JOIN on
# purpose, so that time entries whose issue is *not* visible are still listed
# with a blank issue rather than being dropped from the result set.
#
# The fix below rebuilds the same condition with zero subqueries, by
# evaluating the project-scoped parts in Ruby and inlining the resulting
# project ids as literals. The per-role issue visibility rules (which contain
# no subqueries) are reproduced verbatim from Issue.visible_condition.
#
# Semantics are preserved exactly:
#   * admins: all issues in project_tracking-enabled projects
#   * other users: OR over their roles, each role contributing
#     (project ids for that role) AND (that role's issue visibility rule)
#   * the builtin non-member/anonymous role contributes public projects that
#     the principal has no explicit membership on
#
# This file is a no-op when not running on TiDB/MySQL, so the same stack can
# be pointed back at PostgreSQL without removing it.
#
# NOTE: this monkeypatches Redmine internals. If you upgrade Redmine, re-check
# that TimeEntry.left_join_issue and Issue.visible_condition still look like
# the versions this was written against.
# ---------------------------------------------------------------------------

module TidbCompat
  module_function

  # True when the adapter is one that rejects subqueries in ON clauses.
  def applicable?
    Redmine::Database.mysql?
  rescue StandardError
    false
  end

  # Mirrors the per-role block of Issue.visible_condition, minus the project
  # scoping (which we replace with a literal project id list).
  def issue_visibility_sql(role, user)
    table = Issue.table_name
    conn = ActiveRecord::Base.connection

    sql =
      if user.id && user.logged?
        case role.issues_visibility
        when 'all'
          '1=1'
        when 'default'
          user_ids = [user.id] + user.groups.pluck(:id).compact
          "(#{table}.is_private = #{conn.quoted_false}" \
            " OR #{table}.author_id = #{user.id}" \
            " OR #{table}.assigned_to_id IN (#{user_ids.join(',')}))"
        when 'own'
          user_ids = [user.id] + user.groups.pluck(:id).compact
          "(#{table}.author_id = #{user.id}" \
            " OR #{table}.assigned_to_id IN (#{user_ids.join(',')}))"
        else
          '1=0'
        end
      else
        "(#{table}.is_private = #{conn.quoted_false})"
      end

    unless role.permissions_all_trackers?(:view_issues)
      tracker_ids = role.permissions_tracker_ids(:view_issues)
      sql =
        if tracker_ids.any?
          "(#{sql} AND #{table}.tracker_id IN (#{tracker_ids.join(',')}))"
        else
          '1=0'
        end
    end
    sql
  end

  # Project ids that are active/closed AND have the issue_tracking module
  # enabled. Replaces the `base_statement` subquery from
  # Project.allowed_to_condition; evaluated in WHERE, which TiDB supports.
  # Intentionally uncached: these run per request so that enabling/disabling a
  # module or changing memberships takes effect immediately.
  def module_enabled_project_ids
    Project.joins(:enabled_modules)
           .where(:enabled_modules => {:name => 'issue_tracking'})
           .where(:projects => {:status => [Project::STATUS_ACTIVE, Project::STATUS_CLOSED]})
           .distinct
           .pluck(:id)
  end

  # Public projects the principal has no membership on - replaces the
  # `NOT IN (SELECT project_id FROM members ...)` subquery.
  def public_unmembered_project_ids(user)
    principal_ids = [user.id, user.builtin_role&.id].compact
    Project.where(:is_public => true)
           .where.not(:id => Member.where(:user_id => principal_ids).select(:project_id))
           .pluck(:id)
  end

  # A subquery-free equivalent of Issue.visible_condition(user).
  def issue_visible_condition(user)
    enabled = module_enabled_project_ids
    return '1=0' if enabled.empty?

    if user.admin?
      return "projects.id IN (#{enabled.join(',')})"
    end

    clauses = []

    # Builtin role: non-member for logged-in users, anonymous otherwise.
    builtin = user.builtin_role
    if builtin&.allowed_to?(:view_issues)
      ids = public_unmembered_project_ids(user) & enabled
      clauses << "(projects.id IN (#{ids.join(',')}) AND (#{issue_visibility_sql(builtin, user)}))" if ids.any?
    end

    # Explicit project memberships, grouped per role so that a user holding
    # roles with different issues_visibility keeps exactly the rights each
    # role grants.
    user.project_ids_by_role.each do |role, project_ids|
      next unless role.allowed_to?(:view_issues)
      next if role.builtin?

      ids = project_ids & enabled
      next if ids.empty?

      clauses << "(projects.id IN (#{ids.join(',')}) AND (#{issue_visibility_sql(role, user)}))"
    end

    clauses.empty? ? '1=0' : clauses.join(' OR ')
  end
end

# The scope must be redefined AFTER autoloading, since config/initializers/*
# runs before the application's models are loaded. to_prepare runs once the
# app is fully initialized (and again on each reload in development).
Rails.application.config.to_prepare do
  if TidbCompat.applicable?
    TimeEntry.scope :left_join_issue, (lambda do
      joins(
        "LEFT OUTER JOIN #{Issue.table_name}" \
        " ON #{Issue.table_name}.id = #{TimeEntry.table_name}.issue_id" \
        " AND (#{TidbCompat.issue_visible_condition(User.current)})"
      )
    end)
  end
end
