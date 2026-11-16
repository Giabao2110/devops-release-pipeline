# --- EC2 instance role: SSM access + read-only on released artifacts ---------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app_instance" {
  name               = "${var.project}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "read_releases" {
  statement {
    sid       = "ReadReleaseObjects"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/releases/*"]
  }
  statement {
    sid       = "ListReleasePrefix"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["releases/*"]
    }
  }
}

resource "aws_iam_role_policy" "read_releases" {
  name   = "read-releases"
  role   = aws_iam_role.app_instance.id
  policy = data.aws_iam_policy_document.read_releases.json
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project}-instance"
  role = aws_iam_role.app_instance.name
}

# --- CI publisher role: GitHub Actions OIDC, no long-lived access keys -------
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only this repository, and only main or version tags, may publish.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repository}:ref:refs/heads/main",
        "repo:${var.github_repository}:ref:refs/tags/v*",
      ]
    }
  }
}

resource "aws_iam_role" "ci_publisher" {
  name                 = "${var.project}-ci-publisher"
  assume_role_policy   = data.aws_iam_policy_document.github_assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "publish_artifacts" {
  statement {
    sid     = "WriteArtifacts"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.artifacts.arn}/builds/*",
      "${aws_s3_bucket.artifacts.arn}/releases/*",
    ]
  }
}

resource "aws_iam_role_policy" "publish_artifacts" {
  name   = "publish-artifacts"
  role   = aws_iam_role.ci_publisher.id
  policy = data.aws_iam_policy_document.publish_artifacts.json
}
