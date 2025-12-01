'use strict'

const BOT_LOGIN = "github-actions";
const STEP_ANCHOR = "step:4:1";

const GET_COMMENTS_QUERY = `query($owner: String!, $repo: String!, $issueNumber: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $issueNumber) {
      comments(last: 100) {
        nodes {
          id
          author {
            login
          }
          body
          isMinimized
        }
      }
    }
  }
}`;

// BUG: Classifiers are broken and they do nothing, but they must be set.
//      https://github.com/orgs/community/discussions/19865
const MINIMIZE_COMMENT_MUTATION = `
  mutation($id: ID!) {
    minimizeComment(input: {subjectId: $id, classifier: OUTDATED}) {
      clientMutationId
    }
  }
`;

const COMMENT_LOOKUP = "<!-- FORMALITY_LOOKUP -->";

const SUMMARY_HEADER=`
> [!WARNING]
>
> Some formality checks failed.
>
> Consider (re)reading [submissions guidelines](
https://openwrt.org/submitting-patches#submission_guidelines).

<details>
<summary>Failed checks</summary>

Issues marked with an :x: are failing checks.
`;

const SUMMARY_FOOTER=`
</details>
`;

const NO_MODIFY=`
> [!TIP]
>
> PR has _Allow edits and access to secrets by maintainers_ disabled. Consider allowing edits to simplify review.
>
> [More info](
https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/working-with-forks/allowing-changes-to-a-pull-request-branch-created-from-a-fork)
`;

const FEEDBACK=`
Something broken? Consider [providing feedback](
https://github.com/openwrt/actions-shared-workflows/issues).
`;

async function hideOldSummaries({ github, owner, repo, issueNumber }) {
  const result = await github.graphql(GET_COMMENTS_QUERY, { owner, repo, issueNumber });

  const commentsToHide = result.repository.pullRequest.comments.nodes.filter(comment => !comment.isMinimized &&
    comment.author?.login === BOT_LOGIN &&
    comment.body.includes(COMMENT_LOOKUP)
  );

  for (const { id } of commentsToHide) {
    console.log(`Hiding outdated summary comment ${id}`);
    await github.graphql(MINIMIZE_COMMENT_MUTATION, { id });
  }
}

function getJobUrl({ context, jobId }) {
  return `https://github.com/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}/job/${jobId}?pr=${context.issue.number}#${STEP_ANCHOR}`;
}

function getSummaryMessage({ context, jobId, summary }) {
  return `
  ${SUMMARY_HEADER}
  ${summary}
  ${SUMMARY_FOOTER}
  For more details, see the [full job log](${getJobUrl({ context, jobId })}).
  `;
}

function getCommentMessage({ context, jobId, noModify, summary }) {
  return `
  ${summary.length > 0 ? getSummaryMessage({ context, jobId, summary }) : ''}
  ${noModify ? NO_MODIFY : ''}
  ${FEEDBACK}
  ${COMMENT_LOOKUP}
  `;
}

async function processFormalities({
  context,
  github,
  jobId,
  summary,
  warnOnNoModify,
}) {
  const { owner, repo, number: issueNumber } = context.issue;

  await hideOldSummaries({ github, owner, repo, issueNumber });

  // Explicitly check maintainer_can_modify as it might not be set at all
  const { pull_request: pr } = context.payload.pull_request;
  const noModify = warnOnNoModify && pr?.maintainer_can_modify === false;
  summary = summary.trim();
  if (summary.length === 0 && !noModify) {
    console.log('Summary is empty and modify checks passed, skipping posting a comment');
    return;
  }

  console.log("Posting new summary comment");
  const body = getCommentMessage({ context, jobId, noModify, summary });
  return github.rest.issues.createComment({
    issue_number: issueNumber,
    owner,
    repo,
    body,
  });
}

module.exports = processFormalities;
