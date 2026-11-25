// Lab 08：Jenkins 改为 GitOps 发布
// 用法：把 labs/lab07-cicd/Jenkinsfile 里的 stage('Deploy') 整段替换成下面两个 stage
// 新增凭据：gitops-token（Username with password：机器人用户名 + 项目访问令牌，权限 write_repository）

        stage('Update Staging') {
            when { anyOf { branch 'main'; buildingTag() } }
            steps {
                withCredentials([usernamePassword(credentialsId: 'gitops-token',
                                                  usernameVariable: 'GITOPS_USER',
                                                  passwordVariable: 'GITOPS_TOKEN')]) {
                    sh '''
                      docker run --rm \
                        -v "$WORKSPACE":"$WORKSPACE" -w "$WORKSPACE" \
                        --add-host gitlab.lab.local:192.168.56.16 \
                        -e ENV_NAME=staging -e IMAGE_TAG -e GITOPS_USER -e GITOPS_TOKEN -e BUILD_URL \
                        -e GITOPS_REPO=gitlab.lab.local/ops/ops-mall-labs.git \
                        "$CI_TOOLS_IMAGE" bash labs/lab08-gitops/ci-gitops/update-image-tag.sh
                    '''
                }
            }
        }

        stage('Promote Prod') {
            // 只有 v* 标签才进生产，并且要人点“继续”
            when { buildingTag() }
            steps {
                timeout(time: 30, unit: 'MINUTES') {
                    input message: "把 ${env.IMAGE_TAG} 发布到生产（写入 values-prod.yaml）？", ok: '发布'
                }
                withCredentials([usernamePassword(credentialsId: 'gitops-token',
                                                  usernameVariable: 'GITOPS_USER',
                                                  passwordVariable: 'GITOPS_TOKEN')]) {
                    sh '''
                      docker run --rm \
                        -v "$WORKSPACE":"$WORKSPACE" -w "$WORKSPACE" \
                        --add-host gitlab.lab.local:192.168.56.16 \
                        -e ENV_NAME=prod -e IMAGE_TAG -e GITOPS_USER -e GITOPS_TOKEN -e BUILD_URL \
                        -e GITOPS_REPO=gitlab.lab.local/ops/ops-mall-labs.git \
                        "$CI_TOOLS_IMAGE" bash labs/lab08-gitops/ci-gitops/update-image-tag.sh
                    '''
                }
            }
        }
