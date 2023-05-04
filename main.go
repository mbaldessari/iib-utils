package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

var ocpVersions = []string{"v4.10", "v4.11", "v4.12", "v4.13", "4.14", "4.15"}

func main() {

	git := "openshift-gitops-1-gitops-operator-bundle:v"
	nhc := "red-hat-workload-availability-node-healthcheck-operator-bundle:v"
	snr := "red-hat-workload-availability-self-node-remediation-bundle:v"
	nmo := "red-hat-workload-availability-node-maintenance-operator-bundle:v"
	mdr := "red-hat-workload-availability-machine-deletion-remediation-operator-bundle:v"
	far := "red-hat-workload-availability-fence-agents-remediation-bundle:v"
	url := "https://datagrepper.engineering.redhat.com/raw?topic=/topic/VirtualTopic.eng.ci.redhat-container-image.index.built&contains=%s&rows_per_page=20"

	tr := &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	}
	client := &http.Client{Transport: tr}

	for _, component := range []string{nhc, snr, nmo, mdr, far, git}{

		// wrap in func for defer
		func() {
			componentURL := fmt.Sprintf(url, component)
			req, err := http.NewRequest("GET", componentURL, nil)
			if err != nil {
				fmt.Println(err)
				os.Exit(1)
			}

			resp, err := client.Do(req)
			if err != nil {
				fmt.Println(err)
				os.Exit(1)
			}
			defer resp.Body.Close()

			responseBytes, err := io.ReadAll(resp.Body)
			if err != nil {
				fmt.Println(err)
				os.Exit(1)
			}

			messages := &Messages{}
			err = json.Unmarshal(responseBytes, messages)
			if err != nil {
				fmt.Println(err)
				os.Exit(1)
			}

			if len(messages.RawMessages) == 0 {
				fmt.Printf("%s not found, last build too old?!\n\n", component)
				return
			}

			results := make(map[string]Result)
			for i := 0; i < len(messages.RawMessages); i++ {
				message := messages.RawMessages[i].Msg
				ocpVersion := message.Index.OcpVersion
				if _, exists := results[ocpVersion]; exists {
					continue
				}
				generatedAt := message.GeneratedAt.Format(time.RFC1123)
				bundleImage := message.Index.AddedBundleImages[0]
				indexImage := message.Index.IndexImage
				results[ocpVersion] = Result{
					bundleImage: bundleImage,
					ocpVersion:  ocpVersion,
					indexImage:  indexImage,
					generatedAt: generatedAt,
				}
				if done(results) {
					break
				}
			}

			for _, v := range ocpVersions {
				if r, exists := results[v]; exists {
					fmt.Printf("OCP %s\n  %s\n  %s\n  %s\n\n", r.ocpVersion, r.bundleImage, r.indexImage, r.generatedAt)
				}
			}

		}()
	}
}

func done(results map[string]Result) bool {
	for _, v := range ocpVersions {
		if _, exists := results[v]; !exists {
			return false
		}
	}
	return true
}

type Result struct {
	bundleImage string
	ocpVersion  string
	indexImage  string
	generatedAt string
}

type Messages struct {
	Arguments struct {
		Categories    []interface{} `json:"categories"`
		Contains      []string      `json:"contains"`
		Delta         float64       `json:"delta"`
		End           float64       `json:"end"`
		Grouped       bool          `json:"grouped"`
		Meta          []interface{} `json:"meta"`
		NotCategories []interface{} `json:"not_categories"`
		NotPackages   []interface{} `json:"not_packages"`
		NotTopics     []interface{} `json:"not_topics"`
		NotUsers      []interface{} `json:"not_users"`
		Order         string        `json:"order"`
		Packages      []interface{} `json:"packages"`
		Page          int           `json:"page"`
		RowsPerPage   int           `json:"rows_per_page"`
		Start         float64       `json:"start"`
		Topics        []string      `json:"topics"`
		Users         []interface{} `json:"users"`
	} `json:"arguments"`
	Count       int `json:"count"`
	Pages       int `json:"pages"`
	RawMessages []struct {
		Certificate interface{} `json:"certificate"`
		Crypto      interface{} `json:"crypto"`
		Headers     struct {
			CINAME                     string `json:"CI_NAME"`
			CITYPE                     string `json:"CI_TYPE"`
			JMSXUserID                 string `json:"JMSXUserID"`
			Amq6100Destination         string `json:"amq6100_destination"`
			Amq6100OriginalDestination string `json:"amq6100_originalDestination"`
			Category                   string `json:"category"`
			CorrelationId              string `json:"correlation-id"`
			Destination                string `json:"destination"`
			Expires                    string `json:"expires"`
			MessageId                  string `json:"message-id"`
			OriginalDestination        string `json:"original-destination"`
			Persistent                 string `json:"persistent"`
			Priority                   string `json:"priority"`
			Source                     string `json:"source"`
			Subscription               string `json:"subscription"`
			Timestamp                  string `json:"timestamp"`
			Topic                      string `json:"topic"`
			Type                       string `json:"type"`
			Version                    string `json:"version"`
		} `json:"headers"`
		I   int `json:"i"`
		Msg struct {
			Artifact struct {
				AdvisoryId      string `json:"advisory_id"`
				BrewBuildTag    string `json:"brew_build_tag"`
				BrewBuildTarget string `json:"brew_build_target"`
				Component       string `json:"component"`
				FullName        string `json:"full_name"`
				Id              string `json:"id"`
				ImageTag        string `json:"image_tag"`
				Issuer          string `json:"issuer"`
				Name            string `json:"name"`
				Namespace       string `json:"namespace"`
				Nvr             string `json:"nvr"`
				RegistryUrl     string `json:"registry_url"`
				Scratch         string `json:"scratch"`
				Type            string `json:"type"`
			} `json:"artifact"`
			Ci struct {
				Doc   string `json:"doc"`
				Email string `json:"email"`
				Name  string `json:"name"`
				Team  string `json:"team"`
				Url   string `json:"url"`
			} `json:"ci"`
			GeneratedAt time.Time `json:"generated_at"`
			Index       struct {
				AddedBundleImages []string `json:"added_bundle_images"`
				IndexImage        string   `json:"index_image"`
				OcpVersion        string   `json:"ocp_version"`
			} `json:"index"`
			Pipeline struct {
				Build           string `json:"build"`
				CpaasPipelineId string `json:"cpaas_pipeline_id"`
				Id              string `json:"id"`
				Name            string `json:"name"`
				Status          string `json:"status"`
			} `json:"pipeline"`
			Run struct {
				Log string `json:"log"`
				Url string `json:"url"`
			} `json:"run"`
			Timestamp time.Time `json:"timestamp"`
			Version   string    `json:"version"`
		} `json:"msg"`
		MsgId         string      `json:"msg_id"`
		Signature     interface{} `json:"signature"`
		SourceName    string      `json:"source_name"`
		SourceVersion string      `json:"source_version"`
		Timestamp     float64     `json:"timestamp"`
		Topic         string      `json:"topic"`
		Username      interface{} `json:"username"`
	} `json:"raw_messages"`
	Total int `json:"total"`
}
