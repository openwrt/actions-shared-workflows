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

const MINIMIZE_COMMENT_MUTATION = `
  mutation($id: ID!) {
    minimizeComment(input: {subjectId: $id, classifier: OUTDATED}) {
      clientMutationId
    }
  }
`;

const COMMENT_LOOKUP = "Some formality checks failed.";

const SUMMARY_HEADER=`
> [!WARNING]
>
> ${COMMENT_LOOKUP}
>
> Consider (re)reading [submissions guidelines](https://openwrt.org/submitting-patches#submission_guidelines).

<details>
<summary>Failed checks</summary>

Issues marked with an :x: are failing checks.
`;

const SUMMARY_FOOTER=`
</details>
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

async function processFormalities({ github, context, jobId, summary }) {
  const { owner, repo } = context.repo;
  const issueNumber = context.issue.number;

  await hideOldSummaries({ github, owner, repo, issueNumber });

  summary = summary.trim();
  if (summary.length === 0) {
    return;
  }

  console.log("Posting new summary comment");
  const body = getSummaryMessage({ context, jobId, summary });
  return github.rest.issues.createComment({
    issue_number: issueNumber,
    owner,
    repo,
    body,
  });
}

module.exports = processFormalities;
