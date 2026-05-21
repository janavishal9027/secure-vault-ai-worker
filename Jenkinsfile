// Build pipeline for the ai-worker service.
//
// Jenkins ONLY builds + pushes the image and reports IMAGE_TAG / IMAGE_DIGEST.
// Deployment is NOT done here — env-specific config is managed by Helm. To
// roll out a build, edit the Helm image-versions file for the target env
// with the tag + digest this job prints, then commit.
//
// The multi-stage Dockerfile installs Python deps into a venv and stages
// them into a slim runtime image — no Python toolchain needed on the
// Jenkins agent, only Docker.
//
// ---------------------------------------------------------------------------
// Jenkins setup:
//   Credentials (Manage Jenkins > Credentials):
//     dockerhub-kittuvittu   Username/password — Docker Hub user "kittuvittu"
//                            + a push access token as the password.
//   Agent requirements:
//     - docker CLI on PATH for the `jenkins` user (add jenkins to the
//       `docker` group, then restart Jenkins).
// ---------------------------------------------------------------------------

pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    timeout(time: 30, unit: 'MINUTES')
  }

  environment {
    DOCKER_USER = 'kittuvittu'
    IMAGE_REPO  = 'kittuvittu/secure-vault-ai-worker'
    // Image tag = the full commit SHA.
    IMAGE_TAG   = "${env.GIT_COMMIT}"
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        script {
          env.BUILD_DATE = sh(returnStdout: true, script: 'date -u +%Y-%m-%dT%H:%M:%SZ').trim()
        }
      }
    }

    stage('Build & push image') {
      steps {
        withCredentials([usernamePassword(
          credentialsId: 'dockerhub-kittuvittu',
          usernameVariable: 'DH_USER',
          passwordVariable: 'DH_PASS'
        )]) {
          script {
            sh '''
              set -eu
              echo "$DH_PASS" | docker login -u "$DH_USER" --password-stdin

              docker build \
                --build-arg GIT_COMMIT="$IMAGE_TAG" \
                --build-arg BUILD_NUMBER="$BUILD_NUMBER" \
                --build-arg BUILD_DATE="$BUILD_DATE" \
                -t "${IMAGE_REPO}:${IMAGE_TAG}" \
                .

              docker push "${IMAGE_REPO}:${IMAGE_TAG}" | tee push.log
            '''

            env.IMAGE_DIGEST = sh(
              returnStdout: true,
              script: "awk '/digest: sha256:/{print \$3; exit}' push.log"
            ).trim()

            if (!env.IMAGE_DIGEST) {
              sh 'cat push.log >&2'
              error 'Failed to extract image digest from docker push output'
            }
          }
        }
      }
    }

    stage('Report image') {
      steps {
        echo """
================================================================
 IMAGE_REPO    : ${env.IMAGE_REPO}
 IMAGE_TAG     : ${env.IMAGE_TAG}
 IMAGE_DIGEST  : ${env.IMAGE_DIGEST}
 BRANCH        : ${env.BRANCH_NAME ?: env.GIT_BRANCH}
================================================================

To deploy, set the tag + digest in the Helm image-versions file for
the target env (e.g. image-versions/ai-worker-<env>_image.yaml):

  microservices:
    ai-worker:
      image:
        tag: ${env.IMAGE_TAG}
        digest: ${env.IMAGE_DIGEST}

Both fields are required: the digest pins the image immutably so a
re-tag on Docker Hub can't silently change what runs in cluster.
Then commit + push so Helm picks it up.
================================================================
"""
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: 'push.log', allowEmptyArchive: true
      sh 'docker logout || true'
      cleanWs()
    }
  }
}
