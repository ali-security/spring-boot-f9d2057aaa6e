#!/usr/bin/env bash
# Fork-build preparation for the sealed build (runner checkout only; nothing here reaches the jar).
set -euo pipefail

# repo.spring.io answers HTTP 401 to anonymous requests, so the build cannot resolve from it:
# - settings.gradle: drop the repo.spring.io/plugins-release plugin repository and the
#   io.spring.gradle-enterprise-conventions plugin that only it hosted (com.gradle.enterprise stays; it comes
#   from the Gradle plugin portal and backs the gradleEnterprise {} block).
# - buildSrc/build.gradle: grolifant (pulled in by asciidoctor-gradle-jvm) is not on Maven Central
#   or the plugin portal; resolve it from repo.gradle.org instead of repo.spring.io/release.
perl -0pi -e 's#\s*maven \{\s*url .https://repo\.spring\.io/plugins-release.\s*\}##' settings.gradle
perl -0pi -e 's#\s*id "io\.spring\.gradle-enterprise-conventions" version "[^"]*"##' settings.gradle
perl -0pi -e 's#maven \{ url "https://repo\.spring\.io/release" \}#maven { url "https://repo.gradle.org/gradle/libs-releases"; content { includeGroup "org.ysb33r.gradle" } }#' buildSrc/build.gradle
if grep -n 'repo.spring.io/plugins-release\|io.spring.gradle-enterprise-conventions' settings.gradle; then
  echo "settings.gradle rewrite failed" >&2; exit 1
fi
if grep -n 'repo.spring.io' buildSrc/build.gradle; then
  echo "buildSrc/build.gradle rewrite failed" >&2; exit 1
fi

# Gradle prints nothing per test on success; this init script makes the log name every failed
# or skipped test and print a per-task pass/fail/skip summary.
cat > "${RUNNER_TEMP}/test-results.gradle" <<'EOF'
allprojects {
    tasks.withType(Test).configureEach { Test t ->
        t.filter.failOnNoMatchingTests = false
        t.testLogging {
            events "failed", "skipped"
            exceptionFormat "full"
        }
        // After the run, name every skipped test with its reason: the JUnit XML skip message plus
        // the annotations/comments the test source carries on the method and on its class.
        t.doLast {
            def xmlDir = t.reports.junitXml.outputLocation.get().asFile
            def srcDirs = t.project.hasProperty('sourceSets') ? t.project.sourceSets.test.allSource.srcDirs : []
            if (!xmlDir.isDirectory()) return
            def leading = { List<String> lines, int idx ->
                def out = []
                int i = idx - 1
                while (i >= 0) {
                    def s = lines[i].trim()
                    if (s.startsWith('@') || s.startsWith('//') || s.startsWith('*') || s.startsWith('/*') || s.startsWith('"') || s.startsWith(')')) {
                        out.add(0, s); i--
                    } else break
                }
                out.findAll { !it.startsWith('@Test') && !it.startsWith('@Override') }.join(' ')
            }
            xmlDir.eachFileMatch(~/TEST-.*\.xml/) { f ->
                def doc = javax.xml.parsers.DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(f)
                def cases = doc.getElementsByTagName('testcase')
                (0..<cases.length).each { int ci ->
                    def tc = cases.item(ci)
                    def skips = tc.getElementsByTagName('skipped')
                    if (skips.length == 0) return
                    def cls = tc.getAttribute('classname')
                    def name = tc.getAttribute('name')
                    def msg = skips.item(0).getAttribute('message')
                    def top = cls.replaceAll(/\$.*/, '')
                    def simple = cls.tokenize('.').last().tokenize('$').last()
                    def rel = top.replace('.', '/')
                    def src = srcDirs.collect { new File(it, rel + '.java') }.find { it.exists() } ?:
                            srcDirs.collect { new File(it, rel + '.kt') }.find { it.exists() }
                    def methodAnn = ''
                    def classAnn = ''
                    def declaredIn = '-'
                    def assumptions = ''
                    if (src) {
                        def lines = src.readLines()
                        def m = java.util.regex.Pattern.quote(name.replaceAll(/[(\[].*$/, ''))
                        int cidx = lines.findIndexOf { it =~ /\bclass\s+${java.util.regex.Pattern.quote(simple)}\b/ }
                        if (cidx >= 0) classAnn = leading(lines, cidx)
                        // Inherited tests: follow "extends" up the hierarchy to the declaring source file.
                        def cur = src
                        def curLines = lines
                        int idx = -1
                        for (int depth = 0; depth < 6 && cur != null; depth++) {
                            idx = curLines.findIndexOf { it =~ /\b(void|fun)\s+${m}\s*\(/ }
                            if (idx >= 0) break
                            def extLine = curLines.find { it =~ /\bextends\s+\w+/ }
                            String parent = extLine != null ? extLine.replaceAll(/.*\bextends\s+(\w+).*/, '$1') : null
                            cur = null
                            if (parent) {
                                srcDirs.each { d -> if (cur == null && d.isDirectory()) d.eachFileRecurse { ff -> if (cur == null && ff.name == parent + '.java') cur = ff } }
                            }
                            curLines = cur ? cur.readLines() : null
                        }
                        if (idx >= 0) {
                            methodAnn = leading(curLines, idx)
                            declaredIn = cur.name
                            // Assumption-aborted tests carry their reason in the method body.
                            def body = curLines.subList(idx, Math.min(curLines.size(), idx + 25))
                            int end = body.findIndexOf(1) { it =~ /^\s*(@Test|@ParameterizedTest|void |public |protected |private )/ }
                            if (end > 0) body = body.subList(0, end)
                            assumptions = body.findAll { it =~ /(?i)assum/ }.collect { it.trim() }.join(' ')
                        }
                    }
                    println "SKIPPED TEST ${cls} > ${name} | junit message: ${msg ?: '-'} | method source (${declaredIn}): ${methodAnn ?: '-'} | assumption in body: ${assumptions ?: '-'} | class source: ${classAnn ?: '-'}"
                }
            }
        }
        t.afterSuite { desc, result ->
            if (desc.parent == null) {
                println "TEST SUMMARY ${t.path}: ${result.resultType} - ${result.testCount} tests, " +
                        "${result.successfulTestCount} passed, ${result.failedTestCount} failed, " +
                        "${result.skippedTestCount} skipped"
            }
        }
    }
}
EOF
